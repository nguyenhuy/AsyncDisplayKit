//
//  ASDataController.mm
//  AsyncDisplayKit
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import <AsyncDisplayKit/ASDataController.h>

#import <AsyncDisplayKit/_ASHierarchyChangeSet.h>
#import <AsyncDisplayKit/ASAssert.h>
#import <AsyncDisplayKit/ASCellNode.h>
#import <AsyncDisplayKit/ASLayout.h>
#import <AsyncDisplayKit/ASMainSerialQueue.h>
#import <AsyncDisplayKit/ASMultidimensionalArrayUtils.h>
#import <AsyncDisplayKit/ASSection.h>
#import <AsyncDisplayKit/ASThread.h>
#import <AsyncDisplayKit/ASIndexedNodeContext.h>
#import <AsyncDisplayKit/ASDispatch.h>
#import <AsyncDisplayKit/ASInternalHelpers.h>
#import <AsyncDisplayKit/ASCellNode+Internal.h>
#import <AsyncDisplayKit/ASDisplayNode+Subclasses.h>
#import <AsyncDisplayKit/NSIndexSet+ASHelpers.h>

//#define LOG(...) NSLog(__VA_ARGS__)
#define LOG(...)

#define AS_MEASURE_AVOIDED_DATACONTROLLER_WORK 0

#define RETURN_IF_NO_DATASOURCE(val) if (_dataSource == nil) { return val; }
#define ASSERT_ON_EDITING_QUEUE ASDisplayNodeAssertNotNil(dispatch_get_specific(&kASDataControllerEditingQueueKey), @"%@ must be called on the editing transaction queue.", NSStringFromSelector(_cmd))

#define ASNodeContextTwoDimensionalMutableArray NSMutableArray<NSMutableArray<ASIndexedNodeContext *> *>
#define ASNodeContextTwoDimensionalArray        NSArray<NSArray<ASIndexedNodeContext *> *>

// Dictionary with each entry is a pair of "kind" key and two dimensional array of node contexts
#define ASNodeContextTwoDimensionalDictionary               NSDictionary<NSString *, ASNodeContextTwoDimensionalArray *>
// Mutable dictionary with each entry is a pair of "kind" key and two dimensional array of node contexts
#define ASNodeContextTwoDimensionalMutableDictionary        NSMutableDictionary<NSString *, ASNodeContextTwoDimensionalMutableArray *>

#define ASHierarchyChange                         id<NSCopying>

const static NSUInteger kASDataControllerSizingCountPerProcessor = 5;
const static char * kASDataControllerEditingQueueKey = "kASDataControllerEditingQueueKey";
const static char * kASDataControllerEditingQueueContext = "kASDataControllerEditingQueueContext";

NSString * const ASDataControllerRowNodeKind = @"_ASDataControllerRowNodeKind";
NSString * const ASCollectionInvalidUpdateException = @"ASCollectionInvalidUpdateException";

typedef void (^ASDataControllerCompletionBlock)(NSArray<ASIndexedNodeContext *> *contexts, NSArray<ASCellNode *> *nodes);

#if AS_MEASURE_AVOIDED_DATACONTROLLER_WORK
@interface ASDataController (AvoidedWorkMeasuring)
+ (void)_didLayoutNode;
+ (void)_expectToInsertNodes:(NSUInteger)count;
@end
#endif

@interface ASDataController () {
  ASNodeContextTwoDimensionalMutableDictionary *_nodeContexts;       // Main thread only. These are in the dataSource's index space.
  ASNodeContextTwoDimensionalDictionary *_completedNodeContexts;        // Main thread only. These are in the UIKit's index space.
  
  NSInteger _nextSectionID;
  NSMutableArray<ASSection *> *_sections;
  
  BOOL _itemCountsFromDataSourceAreValid;     // Main thread only.
  std::vector<NSInteger> _itemCountsFromDataSource;         // Main thread only.
  
  ASMainSerialQueue *_mainSerialQueue;

  dispatch_queue_t _editingTransactionQueue;  // Serial background queue.  Dispatches concurrent layout and manages _editingNodes.
  dispatch_group_t _editingTransactionGroup;     // Group of all edit transaction blocks. Useful for waiting.
  
  BOOL _initialReloadDataHasBeenCalled;

  struct {
    unsigned int didInsertNodes:1;
    unsigned int didDeleteNodes;
    unsigned int didInsertSections;
    unsigned int didDeleteSections;
  } _delegateFlags;
  
  struct {
    unsigned int constrainedSizeForSupplementaryNodeOfKindAtIndexPath:1;
    unsigned int supplementaryNodeKindsInDataControllerInSections:1;
  } _dataSourceFlags;
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
  
  _nextSectionID = 0;
  _sections = [NSMutableArray array];
  
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
  _delegateFlags.didInsertNodes     = [_delegate respondsToSelector:@selector(dataController:didInsertNodes:atIndexPaths:withAnimationOptions:)];
  _delegateFlags.didDeleteNodes     = [_delegate respondsToSelector:@selector(dataController:didDeleteNodes:atIndexPaths:withAnimationOptions:)];
  _delegateFlags.didInsertSections  = [_delegate respondsToSelector:@selector(dataController:didInsertSectionsAtIndexSet:withAnimationOptions:)];
  _delegateFlags.didDeleteSections  = [_delegate respondsToSelector:@selector(dataController:didDeleteSectionsAtIndexSet:withAnimationOptions:)];
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
  //TODO add back Logs and AS_MEASURE_AVOIDED_DATACONTROLLER_WORK
#if AS_MEASURE_AVOIDED_DATACONTROLLER_WORK
    [ASDataController _expectToInsertNodes:contexts.count];
#endif
  
  if (contexts.count == 0 || _dataSource == nil) {
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
    NSArray<ASCellNode *> *nodes = [self _layoutNodesFromContexts:batchedContexts];
    batchCompletionHandler(batchedContexts, nodes);
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
    return @[];
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
  NSArray<ASIndexedNodeContext *> *newContexts = [self _populateNodeContextsFromDataSourceWithSections:sectionIndexes environment:];

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

//TODO Revisit this
- (void)waitUntilAllUpdatesAreCommitted
{
  ASDisplayNodeAssertMainThread();
  
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);
  
  // Schedule block in main serial queue to wait until all operations are finished that are
  // where scheduled while waiting for the _editingTransactionQueue to finish
  [_mainSerialQueue performBlockOnMainThread:^{ }];
}

#pragma mark - Data Source Access (Calling _dataSource)

- (NSArray<NSIndexPath *> *)_allIndexPathsForNodeContextsOfKind:(NSString *)kind inSections:(NSIndexSet *)sections
{
  ASDisplayNodeAssertMainThread();
  
  if (sections.count == 0 || _dataSource == nil) {
    return @[];
  }
  
  NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray array];
  if ([kind isEqualToString:ASDataControllerRowNodeKind]) {
    std::vector<NSInteger> counts = [self itemCountsFromDataSource];
    [sections enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
      for (NSUInteger sectionIndex = range.location; sectionIndex < NSMaxRange(range); sectionIndex++) {
        NSUInteger itemCount = counts[sectionIndex];
        for (NSUInteger i = 0; i < itemCount; i++) {
          [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:sectionIndex]];
        }
      }
    }];
  } else {
    [sections enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
      for (NSUInteger sectionIndex = range.location; sectionIndex < NSMaxRange(range); sectionIndex++) {
        NSUInteger itemCount = [_dataSource dataController:self supplementaryNodesOfKind:kind inSection:sectionIndex];
        for (NSUInteger i = 0; i < itemCount; i++) {
          [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:sectionIndex]];
        }
      }
    }];
  }
  
  return indexPaths;
}

/**
 * Agressively repopulates supplementary nodes of all kinds for sections that contains some given index paths.
 *
 * @param originalIndexPaths The index paths belongs to sections whose supplementary nodes need to be repopulated.
 * @param environment The trait environment needed to initialize contexts
 * @return YES if at least 1 new contexts was repopulated, NO otherwise.
 */
- (BOOL)_repopulateSupplementaryNodesForAllSectionsContainingIndexPaths:(NSArray<NSIndexPath *> *)originalIndexPaths
                                                            environment:(id<ASTraitEnvironment>)environment
{
  ASDisplayNodeAssertMainThread();
  
  if (originalIndexPaths.count ==  0) {
    return NO;
  }
  
  BOOL result = NO;
  // Get all the sections that need to be repopulated
  NSIndexSet *sectionIndexes = [NSIndexSet as_sectionsFromIndexPaths:originalIndexPaths];
  for (NSString *kind in [self supplementaryKindsInSections:sectionIndexes]) {
    // Step 1: Remove all existing contexts of this kind in these sections
    // TODO: NSEnumerationConcurrent?
    // TODO: Consider using a diffing algorithm here
    [_nodeContexts[kind] enumerateObjectsAtIndexes:sectionIndexes options:0 usingBlock:^(NSMutableArray<ASIndexedNodeContext *> * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
      [obj removeAllObjects];
    }];
    // Step 2: populate new contexts for all index paths in these sections
    BOOL populated = [self _populateNodeContextsOfKind:kind forSections:sectionIndexes environment:environment];
    result = populated ?: result;
  }
  return result;
}

/**
 * Populates and inserts new node contexts of a certain kind for some sections
 * 
 * @param kind The kind of the node contexts, e.g ASDataControllerRowNodeKind
 * @param sections The sections that should be populated by new contexts
 * @param environment The trait environment needed to initialize contexts
 * @return YES if at least 1 new contexts was populated, NO otherwise.
 */
- (BOOL)_populateNodeContextsOfKind:(NSString *)kind
                        forSections:(NSIndexSet *)sections
                        environment:(id<ASTraitEnvironment>)environment
{
  ASDisplayNodeAssertMainThread();
  
  if (sections.count == 0) {
    return NO;
  }
  
  NSArray<NSIndexPath *> *indexPaths = [self _allIndexPathsForNodeContextsOfKind:kind inSections:sections];
  return [self _populateNodeContextsOfKind:kind atIndexPaths:indexPaths environment:environment];
}

/**
 * Populates and inserts new node contexts of a certain kind at some index paths
 *
 * @param kind The kind of the node contexts, e.g ASDataControllerRowNodeKind
 * @param indexPaths The index paths at which new contexts should be populated
 * @param environment The trait environment needed to initialize contexts
 * @return YES if at least 1 new contexts was populated, NO otherwise.
 */
- (BOOL)_populateNodeContextsOfKind:(NSString *)kind
                       atIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
                        environment:(id<ASTraitEnvironment>)environment
{
  ASDisplayNodeAssertMainThread();
  
  if (indexPaths.count == 0 || _dataSource == nil) {
    return NO;
  }
  
  LOG(@"Populating node contexts of kind: %@, for index paths: %@", kind, allIndexPaths);
  NSMutableArray<ASIndexedNodeContext *> *contexts = [NSMutableArray arrayWithCapacity:indexPaths.count];
  for (NSIndexPath *indexPath in indexPaths) {
    BOOL isRowKind = [kind isEqualToString:ASDataControllerRowNodeKind];
    ASCellNodeBlock nodeBlock;
    if (isRowKind) {
      nodeBlock = [_dataSource dataController:self nodeBlockAtIndexPath:indexPath];
    } else {
      nodeBlock = [_dataSource dataController:self supplementaryNodeBlockOfKind:kind atIndexPath:indexPath];
    }
    
    ASSizeRange constrainedSize = [self constrainedSizeForNodeOfKind:kind atIndexPath:indexPath];
    [contexts addObject:[[ASIndexedNodeContext alloc] initWithNodeBlock:nodeBlock
                                                              indexPath:indexPath
                                               supplementaryElementKind:isRowKind ? nil : kind
                                                        constrainedSize:constrainedSize
                                                            environment:environment]];
  }
  
  ASInsertElementsIntoMultidimensionalArrayAtIndexPaths(_nodeContexts[kind], indexPaths, contexts);
  return YES;
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

- (NSArray<NSString *> *)supplementaryKindsInSections:(NSIndexSet *)sections
{
  if (_dataSourceFlags.supplementaryNodeKindsInDataControllerInSections) {
    return [_dataSource supplementaryNodeKindsInDataController:self sections:sections];
  }
  
  return @[];
}

- (ASSizeRange)constrainedSizeForNodeOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  if ([kind isEqualToString:ASDataControllerRowNodeKind]) {
    return [_dataSource dataController:self constrainedSizeForNodeAtIndexPath:indexPath];
  }
  
  if (_dataSourceFlags.constrainedSizeForSupplementaryNodeOfKindAtIndexPath){
    return [_dataSource dataController:self constrainedSizeForSupplementaryNodeOfKind:kind atIndexPath:indexPath];
  }
  
  ASDisplayNodeAssert(NO, @"Unknown constrained size for node of kind %@ by data source %@", kind, _dataSource);
  return ASSizeRangeMake(CGSizeZero, CGSizeZero);
}

#pragma mark - Batching (External API)

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
  
  // Step 1: update _sections and _nodeContexts.
  // After this step, those properties are up-to-date with dataSource's index space.
  [self updateSectionContextsWithChangeSet:changeSet];
  BOOL hasNewContexts = [self updateNodeContextsWithChangeSet:changeSet];
  
  // Prepare loadingNodeContexts to be used in editing queue.
  // Deep copy is critical here, or future edits to the sub-arrays will pollute state between _nodeContexts and _completedNodeContexts on different threads.
  NSMutableArray<ASNodeContextTwoDimensionalArray *> *deepCopiedSections = [NSMutableArray arrayWithCapacity:_nodeContexts.count];
  for (ASNodeContextTwoDimensionalArray *sections in _nodeContexts.allValues) {
    [deepCopiedSections addObject:ASTwoDimensionalArrayDeepMutableCopy(sections)];
  }
  ASNodeContextTwoDimensionalDictionary *loadingNodeContexts = [NSDictionary dictionaryWithObjects:deepCopiedSections
                                                                                           forKeys:_nodeContexts.allKeys];
  
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    // Step 2: Layout **all** new node contexts without batching in background.
    // This step doesn't change any internal state.
    NSMutableArray<ASIndexedNodeContext *> *newContexts = [NSMutableArray array];
    if (hasNewContexts) {
      for (ASNodeContextTwoDimensionalArray *allSections in loadingNodeContexts.allValues) {
        for (NSArray<ASIndexedNodeContext *> *section in allSections) {
          for (ASIndexedNodeContext *context in section) {
            if (context.nodeIfAllocated == nil) [newContexts addObject:context];
          }
        }
      }
    }
    [self batchLayoutNodesFromContexts:newContexts batchSize:newContexts.count batchCompletion:^(id, id) {
      ASSERT_ON_EDITING_QUEUE;
      [_mainSerialQueue performBlockOnMainThread:^{
        // Because loadingNodeContexts is immutable, it can be safely assigned to _loadNodeContexts instead of deep copied.
        _completedNodeContexts = loadingNodeContexts;
        
        // TODO Redo Automatic content offset adjustment by diffing old and new _completedNodeContexts
        
        // Step 3: Now that _completedNodeContexts is ready, call UIKit to update using the original change set.
        [self forwardChangeSetToDelegate:changeSet insertedRowNodes:nil deletedRowNodes:nil animated:animated];
      }];
    }];
  });
}

/**
 * Update _sections based on the given change set.
 * After this method returns, _sections will be up-to-date with dataSource.
 */
- (void)updateSectionContextsWithChangeSet:(_ASHierarchyChangeSet *)changeSet
{
  ASDisplayNodeAssertMainThread();
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeDelete]) {
    [_sections removeObjectsAtIndexes:change.indexSet];
  }
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeInsert]) {
    NSIndexSet *sectionIndexes = change.indexSet;
    [sectionIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
      id<ASSectionContext> context = [_dataSource dataController:self contextForSection:idx];
      ASSection *section = [[ASSection alloc] initWithSectionID:_nextSectionID context:context];
      [_sections insertObject:section atIndex:idx];
      _nextSectionID++;
    }];
  }
}

/**
 * Update _nodeContexts based on the given change set.
 * After this method returns, _nodeContexts will be up-to-date with dataSource's index space.
 *
 * @param changeSet The change set to be processed
 * @return YES if at least one new context was populated, NO otherwise.
 */
- (BOOL)updateNodeContextsWithChangeSet:(_ASHierarchyChangeSet *)changeSet
{
  ASDisplayNodeAssertMainThread();

  __weak id<ASTraitEnvironment> environment = [self.environmentDelegate dataControllerEnvironment];
  BOOL result = NO;
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeDelete]) {
    ASDeleteElementsInMultidimensionalArrayAtIndexPaths(_nodeContexts[ASDataControllerRowNodeKind], change.indexPaths);
    // Aggressively repopulate supplementary nodes (#1773 & #1629)
    BOOL repopulated = [self _repopulateSupplementaryNodesForAllSectionsContainingIndexPaths:change.indexPaths
                                                                                 environment:environment];
    result = repopulated ?: result;
  }

  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeDelete]) {
    NSIndexSet *sectionIndexes = change.indexSet;
    NSMutableArray<NSString *> *kinds = [NSMutableArray arrayWithObject:ASDataControllerRowNodeKind];
    [kinds addObjectsFromArray:[self supplementaryKindsInSections:sectionIndexes]];
    for (NSString *kind in kinds) {
      [_nodeContexts[kind] removeObjectsAtIndexes:sectionIndexes];
    }
  }
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeInsert]) {
    NSIndexSet *sectionIndexes = change.indexSet;
    NSMutableArray<NSString *> *kinds = [NSMutableArray arrayWithObject:ASDataControllerRowNodeKind];
    [kinds addObjectsFromArray:[self supplementaryKindsInSections:sectionIndexes]];
    
    for (NSString *kind in kinds) {
      // Step 1: Ensure _nodeContexts has enough space for new contexts
      NSMutableArray *nodeContextsOfKind = _nodeContexts[kind];
      if (nodeContextsOfKind == nil) {
        nodeContextsOfKind = [NSMutableArray array];
        _nodeContexts[kind] = nodeContextsOfKind;
      }
      NSMutableArray *sectionArray = [NSMutableArray arrayWithCapacity:sectionIndexes.count];
      for (NSUInteger i = 0; i < sectionIndexes.count; i++) {
        [sectionArray addObject:[NSMutableArray array]];
      }
      [nodeContextsOfKind insertObjects:sectionArray atIndexes:sectionIndexes];
      // Step 2: Populate new contexts for all sections
      BOOL populated = [self _populateNodeContextsOfKind:kind forSections:sectionIndexes environment:environment];
      result = populated ?: result;
    }
  }
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeInsert]) {
    BOOL populatedRowNodes = [self _populateNodeContextsOfKind:ASDataControllerRowNodeKind
                                                  atIndexPaths:change.indexPaths
                                                   environment:environment];
    // Aggressively reload supplementary nodes (#1773 & #1629)
    BOOL repopulatedSupplementaryNodes = [self _repopulateSupplementaryNodesForAllSectionsContainingIndexPaths:change.indexPaths
                                                                                                   environment:environment];
    result = (populatedRowNodes || repopulatedSupplementaryNodes) ?: result;
  }
  
  return result;
}

- (void)forwardChangeSetToDelegate:(_ASHierarchyChangeSet *)changeSet
                  insertedRowNodes:(id _Nullable)insertedRowNodes
                   deletedRowNodes:(id _Nullable)deletedRowNodes
                          animated:(BOOL)animated
{
  ASDisplayNodeAssertMainThread();
  
  [_delegate dataControllerBeginUpdates:self];
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeDelete]) {
    if (_delegateFlags.didDeleteNodes) {
      [_delegate dataController:self
                 didDeleteNodes:deletedRowNodes[change]
                   atIndexPaths:change.indexPaths
           withAnimationOptions:change.animationOptions];
    }
  }
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeDelete]) {
    if (_delegateFlags.didDeleteSections) {
      [_delegate dataController:self didDeleteSectionsAtIndexSet:change.indexSet withAnimationOptions:change.animationOptions];
    }
  }
  
  for (_ASHierarchySectionChange *change in [changeSet sectionChangesOfType:_ASHierarchyChangeTypeInsert]) {
    if (_delegateFlags.didInsertSections) {
      [_delegate dataController:self didInsertSectionsAtIndexSet:change.indexSet withAnimationOptions:change.animationOptions];
    }
  }
  
  for (_ASHierarchyItemChange *change in [changeSet itemChangesOfType:_ASHierarchyChangeTypeInsert]) {
    if (_delegateFlags.didInsertNodes) {
      [_delegate dataController:self
                 didInsertNodes:insertedRowNodes[change]
                   atIndexPaths:change.indexPaths
           withAnimationOptions:change.animationOptions];
    }
  }
  
  void (^batchCompletion)(BOOL) = changeSet.completionHandler;
#if ASEVENTLOG_ENABLE
  NSString *changeSetDescription = ASObjectDescriptionMakeTiny(changeSet);
  [_delegate dataController:self endUpdatesAnimated:animated completion:^(BOOL finished) {
    if (batchCompletion != nil) {
      batchCompletion(finished);
    }
    ASDataControllerLogEvent(self, @"finishedUpdate: %@", changeSetDescription);
  }];
#else
  [_delegate dataController:self endUpdatesAnimated:animated completion:batchCompletion];
#endif
}

#pragma mark - Relayout

- (void)relayoutAllNodes
{
  ASDisplayNodeAssertMainThread();
  if (!_initialReloadDataHasBeenCalled) {
    return;
  }
  
  LOG(@"Edit Command - relayoutRows");
  dispatch_group_wait(_editingTransactionGroup, DISPATCH_TIME_FOREVER);
  
  // Can't relayout right away because _completedNodeContexts may not be up-to-date,
  // i.e there might be some nodes that were measured using the old constrained size but haven't been added to _completedNodeContexts
  dispatch_group_async(_editingTransactionGroup, _editingTransactionQueue, ^{
    [_mainSerialQueue performBlockOnMainThread:^{
      for (NSString *kind in _completedNodeContexts) {
        [self _relayoutNodesOfKind:kind];
      }
    }];
  });
}

- (void)_relayoutNodesOfKind:(NSString *)kind
{
  ASDisplayNodeAssertMainThread();
  NSArray *contexts = _completedNodeContexts[kind];
  if (!contexts.count) {
    return;
  }
  
  NSUInteger sectionIndex = 0;
  for (NSMutableArray *section in contexts) {
    NSUInteger rowIndex = 0;
    for (ASIndexedNodeContext *context in section) {
      RETURN_IF_NO_DATASOURCE();
      NSIndexPath *indexPath = [NSIndexPath indexPathForRow:rowIndex inSection:sectionIndex];
      ASSizeRange constrainedSize = [self constrainedSizeForNodeOfKind:kind atIndexPath:indexPath];
      context.constrainedSize = constrainedSize;
      
      // Node may not be allocated yet (e.g node virtualization or same size optimization)
      // Avoid acidentally allocate and layout it
      ASCellNode *node = context.nodeIfAllocated;
      if (node) {
        [self _layoutNode:node withConstrainedSize:constrainedSize];
      }
      
      rowIndex += 1;
    }
    sectionIndex += 1;
  }
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
  return [_completedNodeContexts[ASDataControllerRowNodeKind] count];
}

- (NSUInteger)completedNumberOfRowsInSection:(NSUInteger)section
{
  ASDisplayNodeAssertMainThread();
  NSArray *completedNodes = _completedNodeContexts[ASDataControllerRowNodeKind];
  return (section < completedNodes.count) ? [completedNodes[section] count] : 0;
}

- (ASCellNode *)nodeAtIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  if (indexPath == nil) {
    return nil;
  }
  
  NSArray *contexts = _nodeContexts[ASDataControllerRowNodeKind];
  ASIndexedNodeContext *context = ASGetElementInTwoDimensionalArray(contexts, indexPath);
  return context.nodeIfAllocated;
}

- (ASCellNode *)nodeAtCompletedIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  if (indexPath == nil) {
    return nil;
  }

  NSArray *completedNodes = _completedNodeContexts[ASDataControllerRowNodeKind];
  ASIndexedNodeContext *context = ASGetElementInTwoDimensionalArray(completedNodes, indexPath);
  // Note: Node may not be allocated and laid out yet (e.g node virtualization or same size optimization)
  // TODO: Force synchronous allocation and layout pass in that case?
  return context.node;
}

- (NSIndexPath *)indexPathForNode:(ASCellNode *)cellNode;
{
  ASDisplayNodeAssertMainThread();
  return [self _indexPathForNode:cellNode inContexts:_nodeContexts];
}

- (NSIndexPath *)completedIndexPathForNode:(ASCellNode *)cellNode
{
  ASDisplayNodeAssertMainThread();
  return [self _indexPathForNode:cellNode inContexts:_completedNodeContexts];
}

- (NSIndexPath *)_indexPathForNode:(ASCellNode *)cellNode inContexts:(ASNodeContextTwoDimensionalDictionary *)contexts
{
  ASDisplayNodeAssertMainThread();
  if (cellNode == nil) {
    return nil;
  }
  
  NSString *kind = cellNode.supplementaryElementKind ?: ASDataControllerRowNodeKind;
  ASNodeContextTwoDimensionalArray *sections = contexts[kind];
  
  // Check if the cached index path is still correct.
  NSIndexPath *indexPath = cellNode.cachedIndexPath;
  if (indexPath != nil) {
    ASIndexedNodeContext *context = ASGetElementInTwoDimensionalArray(sections, indexPath);
    // Use nodeIfAllocated to avoid accidental node allocation and layout
    if (context.nodeIfAllocated == cellNode) {
      return indexPath;
    } else {
      indexPath = nil;
    }
  }
  
  // Loop through each section to look for the node context
  NSInteger sectionIdx = 0;
  for (NSArray<ASIndexedNodeContext *> *section in sections) {
    NSUInteger item = [section indexOfObjectPassingTest:^BOOL(ASIndexedNodeContext * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
      return obj.nodeIfAllocated == cellNode;
    }];
    if (item != NSNotFound) {
      indexPath = [NSIndexPath indexPathForItem:item inSection:sectionIdx];
      break;
    }
    sectionIdx += 1;
  }
  cellNode.cachedIndexPath = indexPath;
  return indexPath;
}

/// Returns nodes that can be queried externally.
- (NSArray *)completedNodes
{
  ASDisplayNodeAssertMainThread();
  ASNodeContextTwoDimensionalArray *sections = _completedNodeContexts[ASDataControllerRowNodeKind];
  NSMutableArray<NSMutableArray<ASCellNode *> *> *completedNodes = [NSMutableArray arrayWithCapacity:sections.count];
  for (NSArray<ASIndexedNodeContext *> *section in sections) {
    NSMutableArray<ASCellNode *> *nodesInSection = [NSMutableArray arrayWithCapacity:section.count];
    for (ASIndexedNodeContext *context in section) {
      // Note: Node may not be allocated and laid out yet (e.g node virtualization or same size optimization)
      // TODO: Force synchronous allocation and layout pass in that case?
      [nodesInSection addObject:context.node];
    }
    [completedNodes addObject:nodesInSection];
  }
  return completedNodes;
}

- (void)moveCompletedNodeAtIndexPath:(NSIndexPath *)indexPath toIndexPath:(NSIndexPath *)newIndexPath
{
  ASDisplayNodeAssertMainThread();
  // TODO Revisit this after native move support. Need to update **both**
  // _nodeContexts and _completedNodeContexts through a proper threading tunnel.
  ASMoveElementInTwoDimensionalArray(_nodeContexts[ASDataControllerRowNodeKind], indexPath, newIndexPath);
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
