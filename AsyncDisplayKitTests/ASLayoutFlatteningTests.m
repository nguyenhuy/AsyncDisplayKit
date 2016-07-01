//
//  ASLayoutFlatteningTests.m
//  AsyncDisplayKit
//
//  Created by Huy Nguyen on 21/06/16.
//  Copyright © 2016 Facebook. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <AsyncDisplayKit/AsyncDisplayKit.h>

@interface ASLayoutFlatteningTests : XCTestCase
@end

@implementation ASLayoutFlatteningTests

- (void)testFlattenSingleNodeLayoutTree
{
  // Need to strongly hold layoutable objects here because ASLayout.layoutableObject is a weak reference
  ASDisplayNode *rootNode = [[ASDisplayNode alloc] init];
  ASLayout *rootLayout = [ASLayout layoutWithLayoutableObject:rootNode
                                         constrainedSizeRange:ASSizeRangeUnconstrained
                                                         size:CGSizeZero];
  ASLayout *flattenedLayout = [rootLayout filteredNodeLayoutTree];
  XCTAssertTrue(rootNode == flattenedLayout.layoutableObject);
  XCTAssertNotNil(flattenedLayout.sublayouts);
  XCTAssertEqual(flattenedLayout.sublayouts.count, 0);
}

- (void)testFlattenLayoutTreeWithZeroSubnode
{
  // Need to strongly hold layoutable objects here because ASLayout.layoutableObject is a weak reference
  ASDisplayNode *rootNode = [[ASDisplayNode alloc] init];
  NSMutableArray<ASLayoutSpec *> *subspecs = [NSMutableArray array];
  NSMutableArray<ASLayout *> *sublayouts = [NSMutableArray array];
  
  for (int i = 0; i < 5; i++) {
    ASLayoutSpec *subspec = [[ASLayoutSpec alloc] init];
    [subspecs addObject:subspec];
    [sublayouts addObject:[ASLayout layoutWithLayoutableObject:subspec
                                          constrainedSizeRange:ASSizeRangeUnconstrained
                                                          size:CGSizeZero
                                                      position:CGPointZero
                                                    sublayouts:nil]];
  }
  
  ASLayout *rootLayout = [ASLayout layoutWithLayoutableObject:rootNode
                                         constrainedSizeRange:ASSizeRangeUnconstrained
                                                         size:CGSizeZero
                                                   sublayouts:sublayouts];
  
  ASLayout *flattenedLayout = [rootLayout filteredNodeLayoutTree];
  XCTAssertTrue(rootNode == flattenedLayout.layoutableObject);
  XCTAssertNotNil(flattenedLayout.sublayouts);
  XCTAssertEqual(flattenedLayout.sublayouts.count, 0);
}

- (void)testFlattenLayoutTreeWithFlattenedSubnodes
{
  // Need to strongly hold layoutable objects here because ASLayout.layoutableObject is a weak reference
  NSMutableArray<ASDisplayNode *> *subnodes = [NSMutableArray array];
  NSMutableArray<ASLayout *> *flattenedSublayouts = [NSMutableArray array];
  int numberOfSubnodes = 0;
  CGSize subnodesSize = CGSizeMake(100, 100);
  CGPoint subnodesPosition = CGPointMake(10, 10);
  
  for (int i = 0; i < 5; i++) {
    ASDisplayNode *subsubnode = [[ASDisplayNode alloc] init];
    [subnodes addObject:subsubnode];
    
    ASLayout *subsublayout = [ASLayout layoutWithLayoutableObject:subsubnode
                                          constrainedSizeRange:ASSizeRangeUnconstrained
                                                          size:CGSizeZero
                                                      position:CGPointZero
                                                    sublayouts:nil];
    
    ASDisplayNode *subnode = [[ASDisplayNode alloc] init];
    [subnodes addObject:subnode];
    
    ASLayout *sublayout = [ASLayout layoutWithLayoutableObject:subnode
                                          constrainedSizeRange:ASSizeRangeUnconstrained
                                                          size:subnodesSize
                                                    sublayouts:@[subsublayout]];
    [flattenedSublayouts addObject:[ASLayout layoutWithLayout:[sublayout filteredNodeLayoutTree]
                                                     position:subnodesPosition]];
    numberOfSubnodes++;
  }
  
  CGPoint insetLayoutPosition = CGPointMake(10, 10);
  ASLayoutSpec *insetLayoutSpec = [[ASLayoutSpec alloc] init];
  ASLayout *insetLayout = [ASLayout layoutWithLayoutableObject:insetLayoutSpec
                                          constrainedSizeRange:ASSizeRangeUnconstrained
                                                          size:CGSizeMake(200, 200)
                                                      position:insetLayoutPosition
                                                    sublayouts:flattenedSublayouts];
  
  ASDisplayNode *rootNode = [[ASDisplayNode alloc] init];
  ASLayout *rootLayout = [ASLayout layoutWithLayoutableObject:rootNode
                                         constrainedSizeRange:ASSizeRangeUnconstrained
                                                         size:CGSizeMake(300, 300)
                                                   sublayouts:@[insetLayout]];
  ASLayout *flattenedRootLayout = [rootLayout filteredNodeLayoutTree];
  
  XCTAssertTrue(rootNode == flattenedRootLayout.layoutableObject);
  XCTAssertNotNil(flattenedRootLayout.sublayouts);
  XCTAssertEqual(flattenedRootLayout.sublayouts.count, numberOfSubnodes);
  
  CGPoint subnodesAbsolutePosition = CGPointMake(subnodesPosition.x + insetLayoutPosition.x,
                                                 subnodesPosition.y + insetLayoutPosition.y);
  for (ASLayout *sublayout in flattenedRootLayout.sublayouts) {
    XCTAssertTrue([sublayout.layoutableObject isKindOfClass:[ASDisplayNode class]]);
    XCTAssertNotEqual([subnodes indexOfObject:(ASDisplayNode *)sublayout.layoutableObject], NSNotFound);
    XCTAssertTrue(CGPointEqualToPoint(subnodesAbsolutePosition, sublayout.position));
    XCTAssertTrue(CGSizeEqualToSize(subnodesSize, sublayout.size));
  }
}

- (void)testFlattenLayoutTreeWithUnflattenedSubnodes
{
  // Need to strongly hold layoutable objects here because ASLayout.layoutableObject is a weak reference
  NSMutableArray<ASDisplayNode *> *subnodes = [NSMutableArray array];
  NSMutableArray<ASLayout *> *flattenedSublayouts = [NSMutableArray array];
  int numberOfSubnodes = 0;
  CGSize subnodesSize = CGSizeMake(100, 100);
  CGPoint subnodesPosition = CGPointMake(10, 10);
  
  for (int i = 0; i < 5; i++) {
    ASDisplayNode *subsubnode = [[ASDisplayNode alloc] init];
    [subnodes addObject:subsubnode];
    
    ASLayout *subsublayout = [ASLayout layoutWithLayoutableObject:subsubnode
                                             constrainedSizeRange:ASSizeRangeUnconstrained
                                                             size:subnodesSize
                                                         position:CGPointZero
                                                       sublayouts:nil];
    
    ASDisplayNode *subnode = [[ASDisplayNode alloc] init];
    [subnodes addObject:subnode];
    
    ASLayout *sublayout = [ASLayout layoutWithLayoutableObject:subnode
                                          constrainedSizeRange:ASSizeRangeUnconstrained
                                                          size:subnodesSize
                                                      position:subnodesPosition
                                                    sublayouts:@[subsublayout]];
    [flattenedSublayouts addObject:sublayout];
    numberOfSubnodes += 2;
  }
  
  CGPoint insetLayoutPosition = CGPointMake(10, 10);
  ASLayoutSpec *insetLayoutSpec = [[ASLayoutSpec alloc] init];
  ASLayout *insetLayout = [ASLayout layoutWithLayoutableObject:insetLayoutSpec
                                          constrainedSizeRange:ASSizeRangeUnconstrained
                                                          size:CGSizeMake(200, 200)
                                                      position:insetLayoutPosition
                                                    sublayouts:flattenedSublayouts];
  
  ASDisplayNode *rootNode = [[ASDisplayNode alloc] init];
  ASLayout *rootLayout = [ASLayout layoutWithLayoutableObject:rootNode
                                         constrainedSizeRange:ASSizeRangeUnconstrained
                                                         size:CGSizeMake(300, 300)
                                                   sublayouts:@[insetLayout]];
  ASLayout *flattenedRootLayout = [rootLayout filteredNodeLayoutTree];
  
  XCTAssertTrue(rootNode == flattenedRootLayout.layoutableObject);
  XCTAssertNotNil(flattenedRootLayout.sublayouts);
  XCTAssertEqual(flattenedRootLayout.sublayouts.count, subnodes.count);
  
  CGPoint subnodesAbsolutePosition = CGPointMake(subnodesPosition.x + insetLayoutPosition.x,
                                                 subnodesPosition.y + insetLayoutPosition.y);
  for (ASLayout *sublayout in flattenedRootLayout.sublayouts) {
    XCTAssertTrue([sublayout.layoutableObject isKindOfClass:[ASDisplayNode class]]);
    XCTAssertNotEqual([subnodes indexOfObject:(ASDisplayNode *)sublayout.layoutableObject], NSNotFound);
    XCTAssertTrue(CGPointEqualToPoint(subnodesAbsolutePosition, sublayout.position));
    XCTAssertTrue(CGSizeEqualToSize(subnodesSize, sublayout.size));
  }
}

@end
