#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import "XTFileListDataSourceBase.h"

@class XTCommitHeaderViewController;
@class XTFileChangesDataSource;
@class XTFileDiffController;
@class XTFileTreeDataSource;
@class XTPreviewController;
@class XTRepository;
@class XTTextPreviewController;

@protocol XTFileChangesModel;

extern const CGFloat kChangeImagePadding;

/**
  Interface for a controller that displays file content in some form.
 */
@protocol XTFileContentController <NSObject>

/// Clears the display for when nothing is selected.
- (void)clear;
/// Displays the content from the given file model.
/// @param path The repository-relative file path.
/// @param model The model to read data from.
/// @param staged Whether to show staged content.
- (void)loadPath:(NSString*)path
           model:(id<XTFileChangesModel>)model
          staged:(BOOL)staged NS_SWIFT_NAME(load(path:model:staged:));

@property (readonly) BOOL canSetWhitespace;
@property (readonly) BOOL canSetTabWidth;

@end
