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
#import "ASAssert.h"
@implementation ASSection

- (instancetype)init
{
  // -[NSProxy init] is undefined
  if (self) {
    _nodes = [NSMutableArray<ASCellNode *> array];
  }
  return self;
}

#pragma mark NSMutableArray methods forwarding

- (BOOL)conformsToProtocol:(Protocol *)aProtocol
{
  return [_nodes conformsToProtocol:aProtocol] || [super conformsToProtocol:aProtocol];
}

- (BOOL)respondsToSelector:(SEL)aSelector
{
  return [_nodes respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector
{
  if ([self shouldForwardSelector:aSelector]) {
    return _nodes;
  }
  
  if ([self respondsToSelector:aSelector]) {
    return self;
  }
  
  return nil;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
  // Check for a compiled definition for the selector
  NSMethodSignature *methodSignature = nil;
  if ([self shouldForwardSelector:aSelector]) {
    methodSignature = [[NSMutableArray class] instanceMethodSignatureForSelector:aSelector];
  } else {
    methodSignature = [[ASSection class] instanceMethodSignatureForSelector:aSelector];
  }
  
  // Unfortunately, in order to get this object to work properly, the use of a method which creates an NSMethodSignature
  // from a C string. -methodSignatureForSelector is called when a compiled definition for the selector cannot be found.
  // This is the place where we have to create our own dud NSMethodSignature. This is necessary because if this method
  // returns nil, a selector not found exception is raised. The string argument to -signatureWithObjCTypes: outlines
  // the return type and arguments to the message. To return a dud NSMethodSignature, pretty much any signature will
  // suffice. Since the -forwardInvocation call will do nothing if self does not respond to the selector,
  // the dud NSMethodSignature simply gets us around the exception.
  return methodSignature ?: [NSMethodSignature signatureWithObjCTypes:"@^v^c"];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
  // If we are down here this means self and _nodes where nil. Just don't do anything to prevent a crash
}

- (BOOL)shouldForwardSelector:(SEL)selector
{
  return (selector != @selector(mutableCopy)) &&
          selector != @selector(isKindOfClass:) &&
          [_nodes respondsToSelector:selector];
}

#pragma mark NSMutableCopying

- (id)mutableCopy
{
  ASSection *copy = [[ASSection alloc] init];
  copy->_nodes = [_nodes mutableCopy];
  copy->_context = _context;
  return copy;
}

#pragma mark NSFastEnumeration

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(__unsafe_unretained id  _Nonnull *)buffer count:(NSUInteger)len
{
  return [_nodes countByEnumeratingWithState:state objects:buffer count:len];
}

@end
