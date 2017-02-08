//
//  ASCollectionDataController.h
//  AsyncDisplayKit
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import <UIKit/UIKit.h>

#import <AsyncDisplayKit/ASDataController.h>
#import <AsyncDisplayKit/ASDimension.h>

@class ASDisplayNode;
@class ASCollectionDataController;
@protocol ASSectionContext;

NS_ASSUME_NONNULL_BEGIN

@interface ASCollectionDataController : ASDataController

- (nullable ASCellNode *)supplementaryNodeOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath;

- (nullable id<ASSectionContext>)contextForSection:(NSInteger)section;

@end

NS_ASSUME_NONNULL_END
