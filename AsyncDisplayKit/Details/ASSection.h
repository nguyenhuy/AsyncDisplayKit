//
//  ASSection.h
//  AsyncDisplayKit
//
//  Created by Huy Nguyen on 28/08/16.
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import <Foundation/Foundation.h>
#import "ASSectionContext.h"

@class ASCellNode;

@interface ASSection : NSProxy <NSMutableCopying, NSFastEnumeration>

@property (nonatomic, strong, nonnull) NSMutableArray<ASCellNode *> *nodes;
@property (nonatomic, strong, nullable) id<ASSectionContext> context;

- (instancetype _Nullable)init;

@end
