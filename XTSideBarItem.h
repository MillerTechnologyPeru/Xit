//
//  XTSideBarItem.h
//  Xit
//
//  Created by German Laullon on 17/07/11.
//  Copyright 2011 VMware, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "XTSideBarItem.h"

@interface XTSideBarItem : NSObject
{
    @private
    NSString *title;
    NSMutableArray *childrens;
}

- (id)initWithTitle:(NSString *)theTitle;
- (NSString *)title;
- (NSInteger)numberOfChildrens;
- (id)children:(NSInteger)index;
- (void)addchildren:(XTSideBarItem *)child;

@end
