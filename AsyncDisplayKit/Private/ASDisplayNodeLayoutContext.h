//
//  ASDisplayNodeLayoutContext.h
//  AsyncDisplayKit
//
//  Created by Huy Nguyen on 3/8/16.
//  Copyright © 2016 Facebook. All rights reserved.
//

#import "ASDimension.h"
#import "_ASTransitionContext.h"

@class ASDisplayNode;
@class ASLayout;

@interface ASDisplayNodeLayoutContext : NSObject <_ASTransitionContextLayoutDelegate>

@property (nonatomic, readonly, weak) ASDisplayNode *node;
@property (nonatomic, readonly, strong) ASLayout *previousLayout;
@property (nonatomic, readonly, assign) ASSizeRange previousConstrainedSize;

- (instancetype)initWithNode:(ASDisplayNode *)node
              previousLayout:(ASLayout *)previousLayout
     previousConstrainedSize:(ASSizeRange)previousConstrainedSize;

- (void)applySubnodeInsertions;

- (void)applySubnodeRemovals;

@end
