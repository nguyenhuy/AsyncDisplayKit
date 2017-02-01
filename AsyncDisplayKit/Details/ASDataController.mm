//
//  ASDataController.mm
//  AsyncDisplayKit
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "ASDataController.h"

#import "_ASHierarchyChangeSet.h"
#import "ASAssert.h"
#import "ASCellNode.h"
#import "ASEnvironmentInternal.h"
#import "ASLayout.h"
#import "ASMainSerialQueue.h"
#import "ASMultidimensionalArrayUtils.h"
#import "ASThread.h"
#import "ASIndexedNodeContext.h"
#import "ASDataController+Subclasses.h"
#import "ASDispatch.h"
#import "ASInternalHelpers.h"
#import "ASCellNode+Internal.h"

//#define LOG(...) NSLog(__VA_ARGS__)
#define LOG(...)

#define AS_MEASURE_AVOIDED_DATACONTROLLER_WORK 0

#define RETURN_IF_NO_DATASOURCE(val) if (_dataSource == nil) { return val; }
#define ASSERT_ON_EDITING_QUEUE ASDisplayNodeAssertNotNil(dispatch_get_specific(&kASDataControllerEditingQueueKey), @"%@ must be called on the editing transaction queue.", NSStringFromSelector(_cmd))

const static NSUInteger kASDataControllerSizingCountPerProcessor = 5;
const static char * kASDataControllerEditingQueueKey = "kASDataControllerEditingQueueKey";
const static char * kASDataControllerEditingQueueContext = "kASDataControllerEditingQueueContext";

NSString * const ASDataControllerRowNodeKind = @"_ASDataControllerRowNodeKind";
NSString * const ASCollectionInvalidUpdateException = @"ASCollectionInvalidUpdateException";

#if AS_MEASURE_AVOIDED_DATACONTROLLER_WORK
@interface ASDataController (AvoidedWorkMeasuring)
+ (void)_didLayoutNode;
+ (void)_expectToInsertNodes:(NSUInteger)count;
@end
#endif

@interface ASDataController () {
  NSMutableDictionary *_nodeContexts;       // Main thread only. This is modified immediately during edits i.e. these are in the dataSource's index space.
  NSMutableDictionary<NSString *, NSMutableArray *> *_completedNodes;       // Main thread only.  External data access can immediately query this if _externalCompletedNodes is unavailable.
  BOOL _itemCountsFromDataSourceAreValid;     // Main thread only.
  std::vector<NSInteger> _itemCountsFromDataSource;         // Main thread only.
  
  ASMainSerialQueue *_mainSerialQueue;

  dispatch_queue_t _editingTransactionQueue;  // Serial background queue.  Dispatches concurrent layout and manages _editingNodes.
  dispatch_group_t _editingTransactionGroup;     // Group of all edit transaction blocks. Useful for waiting.
  
  BOOL _initialReloadDataHasBeenCalled;

  BOOL _delegateDidInsertNodes;
  BOOL _delegateDidDeleteNodes;
  BOOL _delegateDidInsertSections;
  BOOL _delegateDidDeleteSections;
}

@end

@implementation ASDataController

#pragma mark - Lifecycle

- (instancetype)initWithDataSource:(id<ASDataControllerSource>)dataSource eventLog:(ASEventLog *)eventLog
{
  if (!(self = [super init])) {
    return nil;
  }
  
  _dataSource = dataSource;
  
#if ASEVENTLOG_ENABLE
  _eventLog = eventLog;
#endif
  
  _nodeContexts = [NSMutableDictionary dictionary];
  _completedNodes = [NSMutableDictionary dictionary];
  
  _nodeContexts[ASDataControllerRowNodeKind] = [NSMutableArray array];
  _completedNodes[ASDataControllerRowNodeKind] = [NSMutableArray array];
  
  _mainSerialQueue = [[ASMainSerialQueue alloc] init];
  
  const char *queueName = [[NSString stringWithFormat:@"org.AsyncDisplayKit.ASDataController.editingTransactionQueue:%p", self] cStringUsingEncoding:NSASCIIStringEncoding];
  _editingTransactionQueue = dispatch_queue_create(queueName, DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(_editingTransactionQueue, &kASDataControllerEditingQueueKey, &kASDataControllerEditingQueueContext, NULL);
  _editingTransactionGroup = dispatch_group_create();
  
  return self;
}

- (instancetype)init
{
  ASDisplayNodeFailAssert(@"Failed to call designated initializer.");
  id<ASDataControllerSource> fakeDataSource = nil;
  ASEventLog *eventLog = nil;
  return [self initWithDataSource:fakeDataSource eventLog:eventLog];
}

- (void)setDelegate:(id<ASDataControllerDelegate>)delegate
{
  if (_delegate == delegate) {
    return;
  }
  
  _delegate = delegate;
  
  // Interrogate our delegate to understand its capabilities, optimizing away expensive respondsToSelector: calls later.
  _delegateDidInsertNodes     = [_delegate respondsToSelector:@selector(dataController:didInsertNodes:atIndexPaths:withAnimationOptions:)];
  _delegateDidDeleteNodes     = [_delegate respondsToSelector:@selector(dataController:didDeleteNodes:atIndexPaths:withAnimationOptions:)];
  _delegateDidInsertSections  = [_delegate respondsToSelector:@selector(dataController:didInsertSections:atIndexSet:withAnimationOptions:)];
  _delegateDidDeleteSections  = [_delegate respondsToSelector:@selector(dataController:didDeleteSectionsAtIndexSet:withAnimationOptions:)];
}

+ (NSUInteger)parallelProcessorCount
{
  static NSUInteger parallelProcessorCount;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    parallelProcessorCount = [[NSProcessInfo processInfo] activeProcessorCount];
  });

  return parallelProcessorCount;
}

#pragma mark - Cell Layout

- (void)batchLayoutNodesFromContexts:(NSArray<ASIndexedNodeContext *> *)contexts batchSize:(NSUInteger)batchSize batchCompletion:(ASDataControllerCompletionBlock)batchCompletionHandler
{
  ASSERT_ON_EDITING_QUEUE;
#if AS_MEASURE_AVOIDED_DATACONTROLLER_WORK
    [ASDataController _expectToInsertNodes:contexts.count];
#endif
  
  if (contexts.count == 0) {
    batchCompletionHandler(@[], @[]);
    return;
  }

  ASProfilingSignpostStart(2, _dataSource);
  
  if (batchSize == 0) {
    batchSize = [[ASDataController class] parallelProcessorCount] * kASDataControllerSizingCountPerProcessor;
  }
  NSUInteger count = contexts.count;
  
  // Processing in batches
  for (NSUInteger i = 0; i < count; i += batchSize) {
    NSRange batchedRange = NSMakeRange(i, MIN(count - i, batchSize));
    NSArray<ASIndexedNodeContext *> *batchedContexts = [contexts subarrayWithRange:batchedRange];
    NSArray *nodes = [self _layoutNodesFromContexts:batchedContexts];
    NSArray *indexPaths = [ASIndexedNodeContext indexPathsFromContexts:batchedContexts];
    batchCompletionHandler(nodes, indexPaths);
  }
  
  ASProfilingSignpostEnd(2, _dataSource);
}

/**
 * Measure and layout the given node with the constrained size range.
 */
- (void)_layoutNode:(ASCellNode *)node withConstrainedSize:(ASSizeRange)constrainedSize
{
  CGRect frame = CGRectZero;
  frame.size = [node layoutThatFits:constrainedSize].size;
  node.frame = frame;
}

- (NSArray<ASCellNode *> *)_layoutNodesFromContexts:(NSArray<ASIndexedNodeContext *> *)contexts
{
  ASSERT_ON_EDITING_QUEUE;
  
  NSUInteger nodeCount = contexts.count;
  if (!nodeCount || _dataSource == nil) {
    return nil;
  }

  __strong ASCellNode **allocatedNodeBuffer = (__strong ASCellNode **)calloc(nodeCount, sizeof(ASCellNode *));

  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  ASDispatchApply(nodeCount, queue, 0, ^(size_t i) {
    RETURN_IF_NO_DATASOURCE();

    // Allocate the node.
    ASIndexedNodeContext *context = contexts[i];
    ASCellNode *node = context.node;
    if (node == nil) {
      ASDisplayNodeAssertNotNil(node, @"Node block created nil node; %@, %@", self, self.dataSource);
      node = [[ASCellNode alloc] init]; // Fallback to avoid crash for production apps.
    }
    
    [self _layoutNode:node withConstrainedSize:context.constrainedSize];
#if AS_MEASURE_AVOIDED_DATACONTROLLER_WORK
    [ASDataController _didLayoutNode];
#endif
    allocatedNodeBuffer[i] = node;
  });

  BOOL canceled = _dataSource == nil;

  // Create nodes array
  NSArray *nodes = canceled ? nil : [NSArray arrayWithObjects:allocatedNodeBuffer count:nodeCount];
  
  // Nil out buffer indexes to allow arc to free the stored cells.
  for (int i = 0; i < nodeCount; i++) {
    allocatedNodeBuffer[i] = nil;
  }
  free(allocatedNodeBuffer);

  return nodes;
}

- (ASSizeRange)constrainedSizeForNodeOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
  return [_dataSource dataController:self constrainedSizeForNodeAtIndexPath:indexPath];
}

#pragma mark - External Data Querying + Editing

- (BOOL)insertNodes:(NSArray *)nodes ofKind:(NSString *)kind atIndexPaths:(NSArray *)indexPaths
{
  ASDisplayNodeAssertMainThread();
  if (!indexPaths.count || _dataSource == nil) {
    return NO;
  }

  ASInsertElementsIntoMultidimensionalArrayAtIndexPaths(_completedNodes[kind], indexPaths, nodes);
  return YES;
}

- (NSArray<ASCellNode *> * _Nonnull)deleteNodesOfKind:(NSString *)kind atIndexPaths:(NSArray *)indexPaths
{
  ASDisplayNodeAssertMainThread();
  if (!indexPaths.count || _dataSource == nil) {
    return [NSArray array];
  }

  LOG(@"_deleteNodesAtIndexPaths:%@ ofKind:%@, full index paths in _editingNodes = %@", indexPaths, kind, ASIndexPathsForTwoDimensionalArray(_completedNodes[kind]));
  NSMutableArray *allNodes = _completedNodes[kind];
  NSArray *deletedNodes = ASFindElementsInMultidimensionalArrayAtIndexPaths(allNodes, indexPaths);
  ASDeleteElementsInMultidimensionalArrayAtIndexPaths(allNodes, indexPaths);

  return deletedNodes;
}

- (BOOL)insertSections:(NSMutableArray *)sections ofKind:(NSString *)kind atIndexSet:(NSIndexSet *)indexSet
{
  ASDisplayNodeAssertMainThread();
  if (!indexSet.count|| _dataSource == nil) {
    return NO;
  }

  if (_completedNodes[kind] == nil) {
    _completedNodes[kind] = [NSMutableArray array];
  }
  
  [_completedNodes[kind] insertObjects:sections atIndexes:indexSet];
  return YES;
}

- (BOOL)deleteSections:(NSIndexSet *)indexSet
{
  ASDisplayNodeAssertMainThread();
  if (!indexSet.count || _dataSource == nil) {
    return NO;
  }
  
  [_completedNodes enumerateKeysAndObjectsUsingBlock:^(NSString *  _Nonnull kind, NSMutableArray *sections, BOOL * _Nonnull stop) {
    [sections removeObjectsAtIndexes:indexSet];
  }];
  return YES;
}

#pragma mark - Internal Data Querying + Editing

/**
 * Inserts the specified nodes into the given index paths and notifies the delegate of newly inserted nodes.
 *
 * @discussion Nodes are first inserted into the editing store, then the completed store is replaced by a deep copy
 * of the editing nodes. The delegate is invoked on the main thread.
 */
- (void)_insertNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();
  
  BOOL inserted = [self insertNodes:nodes ofKind:ASDataControllerRowNodeKind atIndexPaths:indexPaths];
  
  //TODO review this
  if (inserted && _delegateDidInsertNodes) {
    [_delegate dataController:self didInsertNodes:nodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
  }
}

/**
 * Removes the specified nodes at the given index paths and notifies the delegate of the nodes removed.
 *
 * @discussion Nodes are first removed from the editing store then removed from the completed store on the main thread.
 * Once the backing stores are consistent, the delegate is invoked on the main thread.
 */
- (void)_deleteNodesAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();
  
  NSArray<ASCellNode *> *deletedNodes = [self deleteNodesOfKind:ASDataControllerRowNodeKind atIndexPaths:indexPaths];
  
  //TODO review this
  if (deletedNodes.count > 0 && _delegateDidDeleteNodes) {
    [_delegate dataController:self didDeleteNodes:deletedNodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
  }
}

/**
 * Inserts sections, represented as arrays, into the backing store at the given indices and notifies the delegate.
 *
 * @discussion The section arrays are inserted into the editing store, then a deep copy of the sections are inserted
 * in the completed store on the main thread. The delegate is invoked on the main thread.
 */
- (void)_insertSections:(NSMutableArray *)sections atIndexSet:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();
  
  BOOL inserted = [self insertSections:sections ofKind:ASDataControllerRowNodeKind atIndexSet:indexSet];
  
  //TODO review this
  if (inserted && _delegateDidInsertSections) {
    [_delegate dataController:self didInsertSectionsAtIndexSet:indexSet withAnimationOptions:animationOptions];
  }
}

/**
 * Removes sections at the given indices from the backing store and notifies the delegate.
 *
 * @discussion Section array are first removed from the editing store, then the associated section in the completed
 * store is removed on the main thread. The delegate is invoked on the main thread.
 */
- (void)_deleteSectionsAtIndexSet:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();
  
  BOOL deleted = [self deleteSections:indexSet];
  
  //TOOD review this
  if (deleted && _delegateDidDeleteSections) {
    [_delegate dataController:self didDeleteSectionsAtIndexSet:indexSet withAnimationOptions:animationOptions];
  }
}

#pragma mark - Initial Load & Full Reload (External API)

- (void)reloadDataWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions completion:(void (^)())completion
{
  [self _reloadDataWithAnimationOptions:animationOptions completion:completion];
}

- (void)reloadDataImmediatelyWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self _reloadDataWithAnimationOptions:animationOptions completion:nil];
  [self waitUntilAllUpdatesAreCommitted];
}

- (void)_reloadDataWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions completion:(void (^)())completion
{
  ASDisplayNodeAssertMainThread();

  _initialReloadDataHasBeenCalled = YES;
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);

  [self invalidateDataSourceItemCounts];
  NSUInteger sectionCount = [self itemCountsFromDataSource].size();
  NSIndexSet *sectionIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, sectionCount)];
  NSArray<ASIndexedNodeContext *> *newContexts = [self _populateNodeContextsFromDataSourceForSections:sectionIndexes];

  // Update _nodeContexts
  NSMutableArray *allContexts = _nodeContexts[ASDataControllerRowNodeKind];
  [allContexts removeAllObjects];
  NSArray *nodeIndexPaths = [ASIndexedNodeContext indexPathsFromContexts:newContexts];
  for (int i = 0; i < sectionCount; i++) {
    [allContexts addObject:[[NSMutableArray alloc] init]];
  }
  ASInsertElementsIntoMultidimensionalArrayAtIndexPaths(allContexts, nodeIndexPaths, newContexts);

  // Allow subclasses to perform setup before going into the edit transaction
  [self prepareForReloadDataWithSectionCount:sectionCount];
  
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    LOG(@"Edit Transaction - reloadData");
    
    /**
     * Leave the current data in the collection view until the first batch of nodes are laid out.
     * Once the first batch is laid out, in one operation, replace all the sections and insert
     * the first batch of items.
     *
     * We previously would replace all the sections immediately, and then start adding items as they
     * were laid out. This resulted in more traffic to the UICollectionView and it also caused all the
     * section headers to bunch up until the items come and fill out the sections.
     */
    __block BOOL isFirstBatch = YES;
    [self batchLayoutNodesFromContexts:newContexts batchSize:0 batchCompletion:^(NSArray<ASCellNode *> *nodes, NSArray<NSIndexPath *> *indexPaths) {
      
      //TODO Main thread here
      
      if (isFirstBatch) {
        // -beginUpdates
        [_mainSerialQueue performBlockOnMainThread:^{
          [_delegate dataControllerBeginUpdates:self];
          [_delegate dataControllerWillDeleteAllData:self];
        }];
        
        // deleteSections:
        // Remove everything that existed before the reload, now that we're ready to insert replacements
        NSUInteger oldSectionCount = [_editingNodes[ASDataControllerRowNodeKind] count];
        if (oldSectionCount) {
          NSIndexSet *indexSet = [[NSIndexSet alloc] initWithIndexesInRange:NSMakeRange(0, oldSectionCount)];
          [self _deleteSectionsAtIndexSet:indexSet withAnimationOptions:animationOptions];
        }
        
        [self willReloadDataWithSectionCount:sectionCount];
        
        // insertSections:
        NSMutableArray *sections = [NSMutableArray arrayWithCapacity:sectionCount];
        for (int i = 0; i < sectionCount; i++) {
          [sections addObject:[[NSMutableArray alloc] init]];
        }
        [self _insertSections:sections atIndexSet:sectionIndexes withAnimationOptions:animationOptions];
      }
      
      // insertItemsAtIndexPaths:
      [self _insertNodes:nodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
      
      if (isFirstBatch) {
        // -endUpdates
        [_mainSerialQueue performBlockOnMainThread:^{
          [_delegate dataController:self endUpdatesAnimated:NO completion:nil];
        }];
        isFirstBatch = NO;
      }
    }];
    
    if (completion) {
      [_mainSerialQueue performBlockOnMainThread:completion];
    }
  });
}

- (void)waitUntilAllUpdatesAreCommitted
{
  ASDisplayNodeAssertMainThread();
  
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);
  
  // Schedule block in main serial queue to wait until all operations are finished that are
  // where scheduled while waiting for the _editingTransactionQueue to finish
  [_mainSerialQueue performBlockOnMainThread:^{ }];
}

#pragma mark - Data Source Access (Calling _dataSource)

/**
 * Fetches row contexts for the provided sections from the data source.
 */
- (NSArray<ASIndexedNodeContext *> *)_populateNodeContextsFromDataSourceForSections:(NSIndexSet *)sections withEnvironment:(id<ASEnvironment>)environment
{
  ASDisplayNodeAssertMainThread();
  
  if (sections.count == 0 || _dataSource == nil) {
    return @[];
  }
  
  std::vector<NSInteger> counts = [self itemCountsFromDataSource];
  NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray array];
  [sections enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
    for (NSUInteger sectionIndex = range.location; sectionIndex < NSMaxRange(range); sectionIndex++) {
      NSUInteger itemCount = counts[sectionIndex];
      for (NSUInteger i = 0; i < itemCount; i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:sectionIndex]];
      }
    }
  }];
  
  return [self _populateNodeContextFromDataSourceForIndexPaths:indexPaths withEnvironment:environment];
}

- (NSArray<ASIndexedNodeContext *> *)_populateNodeContextFromDataSourceForIndexPaths:(NSArray<NSIndexPath *> *)indexPaths withEnvironment:(id<ASEnvironment>)environment
{
  ASDisplayNodeAssertMainThread();
  
  if (indexPaths.count == 0 || _dataSource == nil) {
    return @[];
  }
  
  NSMutableArray<ASIndexedNodeContext *> *contexts = [NSMutableArray arrayWithCapacity:indexPaths.count];
  for (NSIndexPath *indexPath in indexPaths) {
    ASCellNodeBlock nodeBlock = [_dataSource dataController:self nodeBlockAtIndexPath:indexPath];
    ASSizeRange constrainedSize = [self constrainedSizeForNodeOfKind:ASDataControllerRowNodeKind atIndexPath:indexPath];
    [contexts addObject:[[ASIndexedNodeContext alloc] initWithNodeBlock:nodeBlock
                                                 indexPath:indexPath
                                  supplementaryElementKind:nil
                                           constrainedSize:constrainedSize
                                               environment:environment]];
  }
  return contexts;
}

- (void)invalidateDataSourceItemCounts
{
  ASDisplayNodeAssertMainThread();
  _itemCountsFromDataSourceAreValid = NO;
}

- (std::vector<NSInteger>)itemCountsFromDataSource
{
  ASDisplayNodeAssertMainThread();
  if (NO == _itemCountsFromDataSourceAreValid) {
    id<ASDataControllerSource> source = self.dataSource;
    NSInteger sectionCount = [source numberOfSectionsInDataController:self];
    std::vector<NSInteger> newCounts;
    newCounts.reserve(sectionCount);
    for (NSInteger i = 0; i < sectionCount; i++) {
      newCounts.push_back([source dataController:self rowsInSection:i]);
    }
    _itemCountsFromDataSource = newCounts;
    _itemCountsFromDataSourceAreValid = YES;
  }
  return _itemCountsFromDataSource;
}

#pragma mark - Batching (External API)

- (void)beginUpdates
{
  ASDisplayNodeAssertMainThread();
  // TODO: make this -waitUntilAllUpdatesAreCommitted?
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);

  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [_mainSerialQueue performBlockOnMainThread:^{
      LOG(@"beginUpdates - begin updates call to delegate");
      [_delegate dataControllerBeginUpdates:self];
    }];
  });
}

- (void)endUpdatesAnimated:(BOOL)animated completion:(void (^)(BOOL))completion
{
  LOG(@"endUpdatesWithCompletion - beginning");
  ASDisplayNodeAssertMainThread();

  // Running these commands may result in blocking on an _editingTransactionQueue operation that started even before -beginUpdates.
  // Each subsequent command in the queue will also wait on the full asynchronous completion of the prior command's edit transaction.
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [_mainSerialQueue performBlockOnMainThread:^{
      LOG(@"endUpdatesWithCompletion - calling delegate end");
      [_delegate dataController:self endUpdatesAnimated:animated completion:completion];
    }];
  });
}

- (void)updateWithChangeSet:(_ASHierarchyChangeSet *)changeSet animated:(BOOL)animated
{
  ASDisplayNodeAssertMainThread();
  
  void (^batchCompletion)(BOOL) = changeSet.completionHandler;
  
  /**
   * If the initial reloadData has not been called, just bail because we don't have
   * our old data source counts.
   * See ASUICollectionViewTests.testThatIssuingAnUpdateBeforeInitialReloadIsUnacceptable
   * For the issue that UICollectionView has that we're choosing to workaround.
   */
  if (!self.initialReloadDataHasBeenCalled) {
    if (batchCompletion != nil) {
      batchCompletion(YES);
    }
    return;
  }
  
  [self invalidateDataSourceItemCounts];
  
  // Attempt to mark the update completed. This is when update validation will occur inside the changeset.
  // If an invalid update exception is thrown, we catch it and inject our "validationErrorSource" object,
  // which is the table/collection node's data source, into the exception reason to help debugging.
  @try {
    [changeSet markCompletedWithNewItemCounts:[self itemCountsFromDataSource]];
  } @catch (NSException *e) {
    id responsibleDataSource = self.validationErrorSource;
    if (e.name == ASCollectionInvalidUpdateException && responsibleDataSource != nil) {
      [NSException raise:ASCollectionInvalidUpdateException format:@"%@: %@", [responsibleDataSource class], e.reason];
    } else {
      @throw e;
    }
  }
  
  ASDataControllerLogEvent(self, @"triggeredUpdate: %@", changeSet);
  
  NSArray<ASIndexedNodeContext *> *newContexts = [self updateNodeContextsWithChangeSet:changeSet];
  
  ASDataControllerCompletionBlock layoutCompletionBlock = ^(NSArray<ASCellNode *> *nodes, NSArray<NSIndexPath *> *indexPaths) {
    ASSERT_ON_EDITING_QUEUE;
    
    [_mainSerialQueue performBlockOnMainThread:^{
      [self updateCompletedNodesWithChangeSet:changeSet newNodes:nodes indexPaths:indexPaths];
      [self forwardChangeSetToDelegate:changeSet animated:animated];
    }];
  };
  
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    // Layout **all** new contexts without batching
    [self batchLayoutNodesFromContexts:newContexts batchSize:newContexts.count batchCompletion:^(NSArray<ASCellNode *> *nodes, NSArray<NSIndexPath *> *indexPaths) {
      layoutCompletionBlock(nodes, indexPaths);
    }];
  });
}

- (NSArray<ASIndexedNodeContext *> *)updateNodeContextsWithChangeSet:(_ASHierarchyChangeSet *)changeSet
{
  ASDisplayNodeAssertMainThread();
  
  NSMutableArray<ASIndexedNodeContext *> *newContexts = [NSMutableArray array];
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeDelete]) {
    ASDeleteElementsInMultidimensionalArrayAtIndexPaths(_nodeContexts[ASDataControllerRowNodeKind], change.indexPaths);
  }
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeDelete]) {
    [_nodeContexts[ASDataControllerRowNodeKind] removeObjectsAtIndexes:change.indexSet];
  }
  
  __weak id<ASEnvironment> environment = [self.environmentDelegate dataControllerEnvironment];
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeInsert]) {
    NSIndexSet *sections = change.indexSet;
    NSArray<ASIndexedNodeContext *> *contexts = [self _populateNodeContextsFromDataSourceForSections:sections withEnvironment:environment];
    
    NSMutableArray *sectionArray = [NSMutableArray arrayWithCapacity:sections.count];
    for (NSUInteger i = 0; i < sections.count; i++) {
      [sectionArray addObject:[NSMutableArray array]];
    }
    NSMutableArray *allRowContexts = _nodeContexts[ASDataControllerRowNodeKind];
    [allRowContexts insertObjects:sectionArray atIndexes:sections];
    ASInsertElementsIntoMultidimensionalArrayAtIndexPaths(allRowContexts, [ASIndexedNodeContext indexPathsFromContexts:contexts], contexts);
    
    [newContexts addObjectsFromArray:contexts];
  }
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeInsert]) {
    NSArray<ASIndexedNodeContext *> *contexts = [self _populateNodeContextFromDataSourceForIndexPaths:change.indexPaths withEnvironment:environment];
    ASInsertElementsIntoMultidimensionalArrayAtIndexPaths(_nodeContexts[ASDataControllerRowNodeKind], change.indexPaths, contexts);
    [newContexts addObjectsFromArray:contexts];
  }
  
  //TODO handle moves

  return newContexts;
}

- (void)updateCompletedNodesWithChangeSet:(_ASHierarchyChangeSet *)changeSet newNodes:(NSArray<ASCellNode *> *)cellNodes indexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  ASDisplayNodeAssertMainThread();
  
  [self beginUpdates];
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeDelete]) {
    [self deleteRowsAtIndexPaths:change.indexPaths withAnimationOptions:change.animationOptions];
  }
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeDelete]) {
    [self deleteSections:change.indexSet withAnimationOptions:change.animationOptions];
  }
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeInsert]) {
    [self insertSections:change.indexSet withAnimationOptions:change.animationOptions];
  }
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeInsert]) {
    [self insertRowsAtIndexPaths:change.indexPaths withAnimationOptions:change.animationOptions];
  }
  
  void (^batchCompletion)(BOOL) = changeSet.completionHandler;
#if ASEVENTLOG_ENABLE
  NSString *changeSetDescription = ASObjectDescriptionMakeTiny(changeSet);
  [self endUpdatesAnimated:animated completion:^(BOOL finished) {
    if (batchCompletion != nil) {
      batchCompletion(finished);
    }
    ASDataControllerLogEvent(self, @"finishedUpdate: %@", changeSetDescription);
  }];
#else
  [self endUpdatesAnimated:animated completion:batchCompletion];
#endif
}

- (void)forwardChangeSetToDelegate:(_ASHierarchyChangeSet *)changeSet animated:(BOOL)animated
{
  
}

#pragma mark - Section Editing (External API)

- (void)insertSections:(NSIndexSet *)sections withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();
  LOG(@"Edit Command - insertSections: %@", sections);
  if (!_initialReloadDataHasBeenCalled) {
    return;
  }

  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);
  
  [self prepareForInsertSections:sections];
  
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [self willInsertSections:sections];

    LOG(@"Edit Transaction - insertSections: %@", sections);
    NSMutableArray *sectionArray = [NSMutableArray arrayWithCapacity:sections.count];
    for (NSUInteger i = 0; i < sections.count; i++) {
      [sectionArray addObject:[NSMutableArray array]];
    }

    [self _insertSections:sectionArray atIndexSet:sections withAnimationOptions:animationOptions];
  });
}

- (void)deleteSections:(NSIndexSet *)sections withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();
  LOG(@"Edit Command - deleteSections: %@", sections);
  if (!_initialReloadDataHasBeenCalled) {
    return;
  }

  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);

  [self prepareForDeleteSections:sections];
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [self willDeleteSections:sections];

    // remove elements
    LOG(@"Edit Transaction - deleteSections: %@", sections);
    [self _deleteSectionsAtIndexSet:sections withAnimationOptions:animationOptions];
  });
}

#pragma mark - Backing store manipulation optional hooks (Subclass API)

- (void)prepareForReloadDataWithSectionCount:(NSInteger)newSectionCount
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willReloadDataWithSectionCount:(NSInteger)newSectionCount
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)prepareForInsertSections:(NSIndexSet *)sections
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)prepareForDeleteSections:(NSIndexSet *)sections
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willInsertSections:(NSIndexSet *)sections
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willDeleteSections:(NSIndexSet *)sections
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willMoveSection:(NSInteger)section toSection:(NSInteger)newSection
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)prepareForInsertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willInsertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)prepareForDeleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

- (void)willDeleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  // Optional template hook for subclasses (See ASDataController+Subclasses.h)
}

#pragma mark - Row Editing (External API)

- (void)insertRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();
  
  LOG(@"Edit Command - insertRows: %@", indexPaths);
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);

  [self prepareForInsertRowsAtIndexPaths:indexPaths];

  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [self willInsertRowsAtIndexPaths:indexPaths];

    LOG(@"Edit Transaction - insertRows: %@", indexPaths);
    [self _batchLayoutAndInsertNodesFromContexts:contexts withAnimationOptions:animationOptions];
  });
}

- (void)deleteRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssertMainThread();

  LOG(@"Edit Command - deleteRows: %@", indexPaths);

  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);
  
  [self prepareForDeleteRowsAtIndexPaths:sortedIndexPaths];

  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [self willDeleteRowsAtIndexPaths:sortedIndexPaths];

    LOG(@"Edit Transaction - deleteRows: %@", indexPaths);
    [self _deleteNodesAtIndexPaths:sortedIndexPaths withAnimationOptions:animationOptions];
  });
}

- (void)relayoutAllNodes
{
  ASDisplayNodeAssertMainThread();
  if (!_initialReloadDataHasBeenCalled) {
    return;
  }

  LOG(@"Edit Command - relayoutRows");
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);

  // Can't relayout right away because _completedNodes may not be up-to-date,
  // i.e there might be some nodes that were measured using the old constrained size but haven't been added to _completedNodes
  // (see _layoutNodes:atIndexPaths:withAnimationOptions:).
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [_mainSerialQueue performBlockOnMainThread:^{
      for (NSString *kind in _completedNodes) {
        [self _relayoutNodesOfKind:kind];
      }
    }];
  });
}

- (void)_relayoutNodesOfKind:(NSString *)kind
{
  ASDisplayNodeAssertMainThread();
  NSArray *nodes = [self completedNodesOfKind:kind];
  if (!nodes.count) {
    return;
  }
  
  NSUInteger sectionIndex = 0;
  for (NSMutableArray *section in nodes) {
    NSUInteger rowIndex = 0;
    for (ASCellNode *node in section) {
      RETURN_IF_NO_DATASOURCE();
      NSIndexPath *indexPath = [NSIndexPath indexPathForRow:rowIndex inSection:sectionIndex];
      ASSizeRange constrainedSize = [self constrainedSizeForNodeOfKind:kind atIndexPath:indexPath];
      [self _layoutNode:node withConstrainedSize:constrainedSize];
      rowIndex += 1;
    }
    sectionIndex += 1;
  }
}

#pragma mark - Data Querying (Subclass API)

- (NSMutableArray *)editingNodesOfKind:(NSString *)kind
{
  return _editingNodes[kind] ? : [NSMutableArray array];
}

- (NSMutableArray *)completedNodesOfKind:(NSString *)kind
{
  return _completedNodes[kind];
}

#pragma mark - Data Querying (External API)

- (NSUInteger)numberOfSections
{
  ASDisplayNodeAssertMainThread();
  return [_nodeContexts[ASDataControllerRowNodeKind] count];
}

- (NSUInteger)numberOfRowsInSection:(NSUInteger)section
{
  ASDisplayNodeAssertMainThread();
  NSArray *contextSections = _nodeContexts[ASDataControllerRowNodeKind];
  return (section < contextSections.count) ? [contextSections[section] count] : 0;
}

- (NSUInteger)completedNumberOfSections
{
  ASDisplayNodeAssertMainThread();
  return [[self completedNodes] count];
}

- (NSUInteger)completedNumberOfRowsInSection:(NSUInteger)section
{
  ASDisplayNodeAssertMainThread();
  NSArray *completedNodes = [self completedNodes];
  return (section < completedNodes.count) ? [completedNodes[section] count] : 0;
}

- (ASCellNode *)nodeAtIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  if (indexPath == nil) {
    return nil;
  }
  
  NSArray *contexts = _nodeContexts[ASDataControllerRowNodeKind];
  NSInteger section = indexPath.section;
  NSInteger row = indexPath.row;
  ASIndexedNodeContext *context = nil;

  if (section >= 0 && row >= 0 && section < contexts.count) {
    NSArray *completedNodesSection = contexts[section];
    if (row < completedNodesSection.count) {
      context = completedNodesSection[row];
    }
  }
  return context.node;
}

- (ASCellNode *)nodeAtCompletedIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  if (indexPath == nil) {
    return nil;
  }

  NSArray *completedNodes = [self completedNodes];
  NSInteger section = indexPath.section;
  NSInteger row = indexPath.row;
  ASCellNode *node = nil;

  if (section >= 0 && row >= 0 && section < completedNodes.count) {
    NSArray *completedNodesSection = completedNodes[section];
    if (row < completedNodesSection.count) {
      node = completedNodesSection[row];
    }
  }

  return node;
}

- (NSIndexPath *)indexPathForNode:(ASCellNode *)cellNode;
{
  ASDisplayNodeAssertMainThread();
  if (cellNode == nil) {
    return nil;
  }

  NSString *kind = cellNode.supplementaryElementKind ?: ASDataControllerRowNodeKind;
  NSArray *contexts = _nodeContexts[kind];

  // Check if the cached index path is still correct.
  NSIndexPath *indexPath = cellNode.cachedIndexPath;
  if (indexPath != nil) {
    ASIndexedNodeContext *context = ASGetElementInTwoDimensionalArray(contexts, indexPath);
    if (context.nodeIfAllocated == cellNode) {
      return indexPath;
    } else {
      indexPath = nil;
    }
  }

  // Loop through each section to look for the node context
  NSInteger section = 0;
  for (NSArray<ASIndexedNodeContext *> *nodeContexts in contexts) {
    NSUInteger item = [nodeContexts indexOfObjectPassingTest:^BOOL(ASIndexedNodeContext * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
      return obj.nodeIfAllocated == cellNode;
    }];
    if (item != NSNotFound) {
      indexPath = [NSIndexPath indexPathForItem:item inSection:section];
      break;
    }
    section += 1;
  }
  cellNode.cachedIndexPath = indexPath;
  return indexPath;
}

- (NSIndexPath *)completedIndexPathForNode:(ASCellNode *)cellNode
{
  ASDisplayNodeAssertMainThread();
  if (cellNode == nil) {
    return nil;
  }

  NSInteger section = 0;
  // Loop through each section to look for the cellNode
  NSString *kind = cellNode.supplementaryElementKind ?: ASDataControllerRowNodeKind;
  for (NSArray *sectionNodes in [self completedNodesOfKind:kind]) {
    NSUInteger item = [sectionNodes indexOfObjectIdenticalTo:cellNode];
    if (item != NSNotFound) {
      return [NSIndexPath indexPathForItem:item inSection:section];
    }
    section += 1;
  }
  
  return nil;
}

/// Returns nodes that can be queried externally. _externalCompletedNodes is used if available, _completedNodes otherwise.
- (NSArray *)completedNodes
{
  ASDisplayNodeAssertMainThread();
  return _externalCompletedNodes ? : _completedNodes[ASDataControllerRowNodeKind];
}

- (void)moveCompletedNodeAtIndexPath:(NSIndexPath *)indexPath toIndexPath:(NSIndexPath *)newIndexPath
{
  ASDisplayNodeAssertMainThread();
  ASMoveElementInTwoDimensionalArray(_externalCompletedNodes, indexPath, newIndexPath);
  ASMoveElementInTwoDimensionalArray(_completedNodes[ASDataControllerRowNodeKind], indexPath, newIndexPath);
}

@end

#if AS_MEASURE_AVOIDED_DATACONTROLLER_WORK

static volatile int64_t _totalExpectedItems = 0;
static volatile int64_t _totalMeasuredNodes = 0;

@implementation ASDataController (WorkMeasuring)

+ (void)_didLayoutNode
{
    int64_t measured = OSAtomicIncrement64(&_totalMeasuredNodes);
    int64_t expected = _totalExpectedItems;
    if (measured % 20 == 0 || measured == expected) {
        NSLog(@"Data controller avoided work (underestimated): %lld / %lld", measured, expected);
    }
}

+ (void)_expectToInsertNodes:(NSUInteger)count
{
    OSAtomicAdd64((int64_t)count, &_totalExpectedItems);
}

@end
#endif
