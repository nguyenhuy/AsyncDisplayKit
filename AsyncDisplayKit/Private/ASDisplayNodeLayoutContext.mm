//
//  ASDisplayNodeLayoutContext.mm
//  AsyncDisplayKit
//
//  Created by Huy Nguyen on 3/8/16.
//  Copyright © 2016 Facebook. All rights reserved.
//

#import "ASDisplayNodeLayoutContext.h"

#import "ASDisplayNode.h"
#import "ASDisplayNodeInternal.h"
#import "ASDisplayNode+Subclasses.h"
#import "ASLayout.h"

#import <vector>

#import "NSArray+Diffing.h"
#import "ASEqualityHelpers.h"

@implementation ASDisplayNodeLayoutContext {
  NSArray<ASDisplayNode *> *_insertedSubnodes;
  NSArray<ASDisplayNode *> *_removedSubnodes;
  std::vector<NSInteger> _insertedSubnodePositions;
  std::vector<NSInteger> _removedSubnodePositions;
}

- (instancetype)initWithNode:(ASDisplayNode *)node
              previousLayout:(ASLayout *)previousLayout
     previousConstrainedSize:(ASSizeRange)previousConstrainedSize
{
  self = [super init];
  if (self) {
    _node = node;
    _previousLayout = previousLayout;
    _previousConstrainedSize = previousConstrainedSize;
    [self calculateSubnodeOperations];
  }
  return self;
}

- (void)calculateSubnodeOperations
{
  ASLayout *currentLayout = _node.calculatedLayout;
  
  if (_previousLayout) {
    NSIndexSet *insertions, *deletions;
    [_previousLayout.immediateSublayouts asdk_diffWithArray:currentLayout.immediateSublayouts
                                                 insertions:&insertions
                                                  deletions:&deletions
                                               compareBlock:^BOOL(ASLayout *lhs, ASLayout *rhs) {
                                                 return ASObjectIsEqual(lhs.layoutableObject, rhs.layoutableObject);
                                               }];
    filterNodesInLayoutAtIndexes(currentLayout, insertions, &_insertedSubnodes, &_insertedSubnodePositions);
    filterNodesInLayoutAtIndexesWithIntersectingNodes(_previousLayout,
                                                      deletions,
                                                      _insertedSubnodes,
                                                      &_removedSubnodes,
                                                      &_removedSubnodePositions);
  } else {
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [currentLayout.immediateSublayouts count])];
    filterNodesInLayoutAtIndexes(currentLayout, indexes, &_insertedSubnodes, &_insertedSubnodePositions);
    _removedSubnodes = nil;
  }
}

- (void)applySubnodeInsertions
{
  for (NSInteger i = 0; i < [_insertedSubnodes count]; i++) {
    NSInteger p = _insertedSubnodePositions[i];
    [_node insertSubnode:_insertedSubnodes[i] atIndex:p];
  }
}

- (void)applySubnodeRemovals
{
  for (NSInteger i = 0; i < [_removedSubnodes count]; i++) {
    [_removedSubnodes[i] removeFromSupernode];
  }
}

/**
 * @abstract Stores the nodes at the given indexes in the `storedNodes` array, storing indexes in a `storedPositions` c++ vector.
 */
static inline void filterNodesInLayoutAtIndexes(
                                                ASLayout *layout,
                                                NSIndexSet *indexes,
                                                NSArray<ASDisplayNode *> * __strong *storedNodes,
                                                std::vector<NSInteger> *storedPositions
                                                )
{
  filterNodesInLayoutAtIndexesWithIntersectingNodes(layout, indexes, nil, storedNodes, storedPositions);
}

/**
 * @abstract Stores the nodes at the given indexes in the `storedNodes` array, storing indexes in a `storedPositions` c++ vector.
 * @discussion If the node exists in the `intersectingNodes` array, the node is not added to `storedNodes`.
 */
static inline void filterNodesInLayoutAtIndexesWithIntersectingNodes(
                                                                     ASLayout *layout,
                                                                     NSIndexSet *indexes,
                                                                     NSArray<ASDisplayNode *> *intersectingNodes,
                                                                     NSArray<ASDisplayNode *> * __strong *storedNodes,
                                                                     std::vector<NSInteger> *storedPositions
                                                                     )
{
  NSMutableArray<ASDisplayNode *> *nodes = [NSMutableArray array];
  std::vector<NSInteger> positions = std::vector<NSInteger>();
  NSInteger idx = [indexes firstIndex];
  while (idx != NSNotFound) {
    BOOL skip = NO;
    ASDisplayNode *node = (ASDisplayNode *)layout.immediateSublayouts[idx].layoutableObject;
    ASDisplayNodeCAssert(node, @"A flattened layout must consist exclusively of node sublayouts");
    for (ASDisplayNode *i in intersectingNodes) {
      if (node == i) {
        skip = YES;
        break;
      }
    }
    if (!skip) {
      [nodes addObject:node];
      positions.push_back(idx);
    }
    idx = [indexes indexGreaterThanIndex:idx];
  }
  *storedNodes = nodes;
  *storedPositions = positions;
}

#pragma mark - _ASTransitionContextDelegate

- (NSArray<ASDisplayNode *> *)currentSubnodesWithTransitionContext:(_ASTransitionContext *)context
{
  return _node.subnodes;
}

- (NSArray<ASDisplayNode *> *)insertedSubnodesWithTransitionContext:(_ASTransitionContext *)context
{
  return _insertedSubnodes;
}

- (NSArray<ASDisplayNode *> *)removedSubnodesWithTransitionContext:(_ASTransitionContext *)context
{
  return _removedSubnodes;
}

- (ASLayout *)transitionContext:(_ASTransitionContext *)context layoutForKey:(NSString *)key
{
  if ([key isEqualToString:ASTransitionContextFromLayoutKey]) {
    return _previousLayout;
  } else if ([key isEqualToString:ASTransitionContextToLayoutKey]) {
    return _node.calculatedLayout;
  } else {
    return nil;
  }
}
- (ASSizeRange)transitionContext:(_ASTransitionContext *)context constrainedSizeForKey:(NSString *)key
{
  if ([key isEqualToString:ASTransitionContextFromLayoutKey]) {
    return _previousConstrainedSize;
  } else if ([key isEqualToString:ASTransitionContextToLayoutKey]) {
    return _node.constrainedSizeForCalculatedLayout;
  } else {
    return ASSizeRangeMake(CGSizeZero, CGSizeZero);
  }
}

@end
