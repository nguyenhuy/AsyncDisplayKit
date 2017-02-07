//
//  ASCollectionDataController.mm
//  AsyncDisplayKit
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "ASCollectionDataController.h"

#import "ASAssert.h"
#import "ASMultidimensionalArrayUtils.h"
#import "ASCellNode.h"
#import "ASDataController+Subclasses.h"
#import "ASIndexedNodeContext.h"
#import "ASSection.h"
#import "ASSectionContext.h"
#import "NSIndexSet+ASHelpers.h"

//#define LOG(...) NSLog(__VA_ARGS__)
#define LOG(...)

@interface ASCollectionDataController () {
  /**
   * supplementaryKinds can only be accessed on the main thread
   * and so we set this in the -prepare stage, and then read it during the -will
   * stage of each update operation.
   */
  NSArray *_supplementaryKindsForPendingOperation;
}

@end

@implementation ASCollectionDataController {
  NSMutableDictionary<NSString *, NSMutableArray<ASIndexedNodeContext *> *> *_pendingNodeContexts;
}

- (instancetype)initWithDataSource:(id<ASDataControllerSource>)dataSource eventLog:(ASEventLog *)eventLog
{
  self = [super initWithDataSource:dataSource eventLog:eventLog];
  if (self != nil) {
    _pendingNodeContexts = [NSMutableDictionary dictionary];
    _nextSectionID = 0;
    _sections = [NSMutableArray array];
  }
  return self;
}

- (void)prepareForReloadDataWithSectionCount:(NSInteger)newSectionCount
{
  ASDisplayNodeAssertMainThread();
  NSIndexSet *sections = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, newSectionCount)];
  
  [_sections removeAllObjects];
  [self _populatePendingSectionsFromDataSource:sections];
  
  for (NSString *kind in [self supplementaryKindsInSections:sections]) {
    LOG(@"Populating elements of kind: %@", kind);
    NSMutableArray<ASIndexedNodeContext *> *contexts = [NSMutableArray array];
    [self _populateSupplementaryNodesOfKind:kind withSections:sections mutableContexts:contexts];
    _pendingNodeContexts[kind] = contexts;
  }
}

- (void)willReloadDataWithSectionCount:(NSInteger)newSectionCount
{
  NSIndexSet *sectionIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, newSectionCount)];
  
  [self applyPendingSections:sectionIndexes];
  
  [_pendingNodeContexts enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull kind, NSMutableArray<ASIndexedNodeContext *> * _Nonnull contexts, __unused BOOL * _Nonnull stop) {
    // Insert each section
    NSMutableArray *sections = [NSMutableArray arrayWithCapacity:newSectionCount];
    for (int i = 0; i < newSectionCount; i++) {
      [sections addObject:[NSMutableArray array]];
    }
    [self insertSections:sections ofKind:kind atIndexSet:sectionIndexes completion:nil];
    
    [self batchLayoutNodesFromContexts:contexts batchSize:0 batchCompletion:^(NSArray<ASCellNode *> *nodes, NSArray<NSIndexPath *> *indexPaths) {
      [self insertNodes:nodes ofKind:kind atIndexPaths:indexPaths completion:nil];
    }];
  }];
  [_pendingNodeContexts removeAllObjects];
}

- (void)willDeleteSections:(NSIndexSet *)sections
{
  [_sections removeObjectsAtIndexes:sections];
}

- (void)prepareForInsertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  ASDisplayNodeAssertMainThread();
  NSIndexSet *sections = [NSIndexSet as_sectionsFromIndexPaths:indexPaths];
  for (NSString *kind in [self supplementaryKindsInSections:sections]) {
    LOG(@"Populating elements of kind: %@, for index paths: %@", kind, indexPaths);
    NSMutableArray<ASIndexedNodeContext *> *contexts = [NSMutableArray array];
    [self _populateSupplementaryNodesOfKind:kind atIndexPaths:indexPaths mutableContexts:contexts];
    _pendingNodeContexts[kind] = contexts;
  }
}

- (void)willInsertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  [_pendingNodeContexts enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull kind, NSMutableArray<ASIndexedNodeContext *> * _Nonnull contexts, BOOL * _Nonnull stop) {
    [self batchLayoutNodesFromContexts:contexts batchSize:0 batchCompletion:^(NSArray<ASCellNode *> *nodes, NSArray<NSIndexPath *> *indexPaths) {
      [self insertNodes:nodes ofKind:kind atIndexPaths:indexPaths completion:nil];
    }];
  }];

  [_pendingNodeContexts removeAllObjects];
}

- (void)prepareForDeleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  ASDisplayNodeAssertMainThread();
  NSIndexSet *sections = [NSIndexSet as_sectionsFromIndexPaths:indexPaths];
  _supplementaryKindsForPendingOperation = [self supplementaryKindsInSections:sections];
  for (NSString *kind in _supplementaryKindsForPendingOperation) {
    NSMutableArray<ASIndexedNodeContext *> *contexts = [NSMutableArray array];
    [self _populateSupplementaryNodesOfKind:kind atIndexPaths:indexPaths mutableContexts:contexts];
    _pendingNodeContexts[kind] = contexts;
  }
}

- (void)willDeleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
  for (NSString *kind in _supplementaryKindsForPendingOperation) {
    NSArray<NSIndexPath *> *deletedIndexPaths = ASIndexPathsInMultidimensionalArrayIntersectingIndexPaths([self editingNodesOfKind:kind], indexPaths);

    [self deleteNodesOfKind:kind atIndexPaths:deletedIndexPaths completion:nil];

    // If any of the contexts remain after the deletion, re-insert them, e.g.
    // UICollectionElementKindSectionHeader remains even if item 0 is deleted.
    NSMutableArray<ASIndexedNodeContext *> *reinsertedContexts = [NSMutableArray array];
    for (ASIndexedNodeContext *context in _pendingNodeContexts[kind]) {
      if ([deletedIndexPaths containsObject:context.indexPath]) {
        [reinsertedContexts addObject:context];
      }
    }
    
    [self batchLayoutNodesFromContexts:reinsertedContexts batchSize:0 batchCompletion:^(NSArray<ASCellNode *> *nodes, NSArray<NSIndexPath *> *indexPaths) {
      [self insertNodes:nodes ofKind:kind atIndexPaths:indexPaths completion:nil];
    }];
  }
  [_pendingNodeContexts removeAllObjects];
  _supplementaryKindsForPendingOperation = nil;
}

- (void)_populatePendingSectionsFromDataSource:(NSIndexSet *)sectionIndexes
{
  ASDisplayNodeAssertMainThread();
  
  NSMutableArray<ASSection *> *sections = [NSMutableArray arrayWithCapacity:sectionIndexes.count];
  [sectionIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
    id<ASSectionContext> context = [self.collectionDataSource dataController:self contextForSection:idx];
    [sections addObject:[[ASSection alloc] initWithSectionID:_nextSectionID context:context]];
    _nextSectionID++;
  }];
  _pendingSections = sections;
}

- (void)_populateSupplementaryNodesOfKind:(NSString *)kind atIndexPaths:(NSArray<NSIndexPath *> *)indexPaths mutableContexts:(NSMutableArray<ASIndexedNodeContext *> *)contexts
{
  __weak id<ASEnvironment> environment = [self.environmentDelegate dataControllerEnvironment];

  NSMutableIndexSet *sections = [NSMutableIndexSet indexSet];
  for (NSIndexPath *indexPath in indexPaths) {
    [sections addIndex:indexPath.section];
  }

  [sections enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
    for (NSUInteger sec = range.location; sec < NSMaxRange(range); sec++) {
      NSUInteger itemCount = [self.collectionDataSource dataController:self supplementaryNodesOfKind:kind inSection:sec];
      for (NSUInteger i = 0; i < itemCount; i++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:i inSection:sec];
        [self _populateSupplementaryNodeOfKind:kind atIndexPath:indexPath mutableContexts:contexts environment:environment];
      }
    }
  }];
}

#pragma mark - External supplementary store and section context querying

- (ASCellNode *)supplementaryNodeOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  NSArray *nodesOfKind = [self completedNodesOfKind:kind];
  NSInteger section = indexPath.section;
  if (section < nodesOfKind.count) {
    NSArray *nodesOfKindInSection = nodesOfKind[section];
    NSInteger itemIndex = indexPath.item;
    if (itemIndex < nodesOfKindInSection.count) {
      return nodesOfKindInSection[itemIndex];
    }
  }
  return nil;
}

- (id<ASSectionContext>)contextForSection:(NSInteger)section
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssertTrue(section >= 0 && section < _sections.count);
  return _sections[section].context;
}

@end
