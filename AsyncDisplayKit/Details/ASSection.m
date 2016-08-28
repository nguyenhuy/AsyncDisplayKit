//
//  ASSection.m
//  AsyncDisplayKit
//
//  Created by Huy Nguyen on 28/08/16.
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "ASSection.h"
#import "ASSectionContext.h"
#import "ASCellNode.h"
#import "ASAssert.h"

@interface ASSection() {
  NSMutableArray<ASCellNode *> *_nodes;
}

@end

@implementation ASSection

- (instancetype)init
{
  self = [super init];
  if (self) {
    _nodes = [NSMutableArray array];
  }
  return self;
}

- (instancetype)initWithCapacity:(NSUInteger)numItems
{
  self = [super init];
  if (self) {
    _nodes = [NSMutableArray arrayWithCapacity:numItems];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
  self = [super init];
  if (self) {
    _nodes = [[NSMutableArray alloc] initWithCoder:aDecoder];
  }
  return self;
}

- (instancetype)initWithNodes:(NSMutableArray<ASCellNode *> *)nodes
{
  self = [super init];
  if (self) {
    _nodes = [nodes mutableCopy];
  }
  return self;
}

#pragma mark NSArray primitive methods

- (NSUInteger)count
{
  return [_nodes count];
}

- (id)objectAtIndex:(NSUInteger)index
{
  return [_nodes objectAtIndex:index];
}

#pragma mark NSMutableArray primitive methods

- (void)insertObject:(id)anObject atIndex:(NSUInteger)index
{
  [_nodes insertObject:anObject atIndex:index];
}

- (void)removeObjectAtIndex:(NSUInteger)index
{
  [_nodes removeObjectAtIndex:index];
}

- (void)addObject:(id)anObject
{
  [_nodes addObject:anObject];
}

- (void)removeLastObject
{
  [_nodes removeLastObject];
}

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject
{
  [_nodes replaceObjectAtIndex:index withObject:anObject];
}

#pragma mark NSMutableCopying

- (id)mutableCopyWithZone:(NSZone *)zone
{
  ASSection *copy = [self initWithNodes:_nodes];
  copy->_nodes = [_nodes mutableCopyWithZone:zone];
  copy->_context = _context;
  return copy;
}

@end
