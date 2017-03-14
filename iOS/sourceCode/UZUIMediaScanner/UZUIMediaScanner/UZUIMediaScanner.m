/**
 * APICloud Modules
 * Copyright (c) 2014-2015 by APICloud, Inc. All Rights Reserved.
 * Licensed under the terms of the The MIT License (MIT).
 * Please see the license.html included with this distribution for details.
 */

#import "UZUIMediaScanner.h"
#import "UZModule.h"
#import "UZUIAssetsViewController.h"
#import "NSDictionaryUtils.h"
#import "UZAppUtils.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import "UZUIAssetsGroupViewController.h"
#import "UZUIAssetNavigationController.h"
#import <CommonCrypto/CommonDigest.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <Photos/Photos.h>

@interface UZUIMediaScanner ()
<AssetsViewCallBack> {
    NSInteger cbOpenId, cbScannerId, fecthCbId;
    NSMutableDictionary *_scanDict;
    NSMutableArray *_picAry, *_vidAry, *_allAry, *_cBAll;
    NSInteger capicity;          //每页数据容量
    BOOL preparedData;           //所需数据是否准备完
    CGSize thumbSize;            //缩略图大小
}

@property (nonatomic, strong) NSMutableArray *assets;
@property (nonatomic, strong) NSMutableDictionary *scanDict;
@property (nonatomic, strong) NSOperationQueue *transPathQueue;
@end

@implementation UZUIMediaScanner

@synthesize assets = _assets;
@synthesize scanDict = _scanDict;

static int fetchPosition = 0;
//static UIImage *imageTrasn = nil;
static char extendKey;

#pragma mark -
#pragma mark  lifeCycle
#pragma mark -

- (void)dispose {
    if (self.assets) {
        [self.assets removeAllObjects];
        self.assets = nil;
    }
    if (_scanDict) {
        self.scanDict = nil;
    }
    if (self.transPathQueue) {
        [self.transPathQueue cancelAllOperations];
        self.transPathQueue = nil;
    }
}

- (NSOperationQueue *)transPathQueue {
    if (!_transPathQueue) {
        _transPathQueue = [[NSOperationQueue alloc]init];
        NSInteger maxOperation = 1;//[[NSProcessInfo processInfo]activeProcessorCount];
        [_transPathQueue setMaxConcurrentOperationCount:maxOperation];
    }
    return _transPathQueue;
}

#pragma mark -
#pragma mark  interface
#pragma mark -

- (void)open:(NSDictionary *)paramsDict_ {
    cbOpenId = [paramsDict_ integerValueForKey:@"cbId" defaultValue:-1];
    [self classify:paramsDict_];
}

- (void)scan:(NSDictionary *)paramsDict_ {
    preparedData = NO;
    fecthCbId = -1;
    fetchPosition = 0;
    self.assets = [NSMutableArray arrayWithCapacity:1];
    _scanDict = [NSMutableDictionary dictionaryWithDictionary:paramsDict_];
    cbScannerId = [paramsDict_ integerValueForKey:@"cbId" defaultValue:-1];
    NSDictionary *thumbSizeInfo = [paramsDict_ dictValueForKey:@"thumbnail" defaultValue:@{}];
    CGFloat thumbW = [thumbSizeInfo floatValueForKey:@"w" defaultValue:100.0];
    CGFloat thumbH = [thumbSizeInfo floatValueForKey:@"h" defaultValue:100.0];
    thumbSize = CGSizeMake(thumbW, thumbH);
    BOOL showGroup = [paramsDict_ boolValueForKey:@"showGroup" defaultValue:NO];
    if (showGroup) {
        [NSThread detachNewThreadSelector:@selector(loadDataSourceInGroup:) toTarget:self withObject:nil];
    } else {
        [NSThread detachNewThreadSelector:@selector(loadDataSource:) toTarget:self withObject:nil];
    }
}

- (void)fetch:(NSDictionary *)paramsDict_ {
    fecthCbId = [paramsDict_ integerValueForKey:@"cbId" defaultValue:-1];
    if (preparedData) {
        [self fetchCallBack];
    } else {
        //创建一个线程，用来取指定页码和数量的照片数据
        NSThread *thread2 = [[NSThread alloc] initWithTarget:self selector:@selector(getSpecifiedData:) object:nil];
        //启动线程
        [thread2 start];
    }
}

- (void)transPath:(NSDictionary *)paramsDict_ {
    NSInteger transCbId = [paramsDict_ integerValueForKey:@"cbId" defaultValue:-1];
    NSString *path = [paramsDict_ stringValueForKey:@"path" defaultValue:nil];
    if (path.length == 0) {
        return;
    }
    //创建NSBlockOperation 来执行每一次转换，图片复制等耗时操作
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        NSString *locStr = [self localPathForAssetLibraryPath:path];
        //回到主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendResultEventWithCallbackId:transCbId dataDict:[NSDictionary dictionaryWithObjectsAndKeys:locStr,@"path", nil] errDict:nil doDelete:YES];
        });
    }];
    [self.transPathQueue addOperation:operation];
    /*
    NSURL *url = [[NSURL alloc] initWithString:path];
    //__block UIImage *imageAss = nil;
    __weak UZUIMediaScanner *wealSelf = self;
    ALAssetsLibraryAssetForURLResultBlock resultblock = ^(ALAsset *myasset) {
        //创建NSBlockOperation 来执行每一次转换，图片复制等耗时操作
        NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
            UIImage *imageTrasn = [UIImage imageWithCGImage:myasset.defaultRepresentation.fullResolutionImage
                                                                                   scale:myasset.defaultRepresentation.scale
                                                                          orientation:(UIImageOrientation)myasset.defaultRepresentation.orientation];
            imageTrasn = [self imageCorrectedForCaptureOrientation:imageTrasn UIImageOrientation:imageTrasn.imageOrientation];
            [wealSelf save:imageTrasn imagePath:path cbId:transCbId];
        }];
        [wealSelf.transPathQueue addOperation:operation];
    };
    ALAssetsLibraryAccessFailureBlock failureblock  = ^(NSError *myerror) {
        NSLog(@"Turbo_UIMediascanner_cant get image - %@",[myerror localizedDescription]);
    };
    ALAssetsLibrary *assetsLibrary;
    assetsLibrary = [self.class defaultAssetsLibrary];
    [assetsLibrary assetForURL:url resultBlock:resultblock failureBlock:failureblock];
     */
}

- (void)getVideoDuration:(NSDictionary *)paramsDict_ {
    NSString *path = [paramsDict_ stringValueForKey:@"path" defaultValue:@""];
    NSInteger duratinCbId = [paramsDict_ integerValueForKey:@"cbId" defaultValue:-1];
    if ([path containsString:@"fs://"] || [path containsString:@"widget://"]) {
        path = [self getPathWithUZSchemeURL:path];
        NSURL *url = [NSURL fileURLWithPath:path];
        if (!url) return;
        AVURLAsset * asset = [AVURLAsset assetWithURL:url];
        CMTime time = [asset duration];
        int duration = ceil(time.value / (float)time.timescale);
        if (duration) {
            [self sendResultEventWithCallbackId:duratinCbId dataDict:@{@"duration" : @(duration)} errDict:nil doDelete:YES];
        }
    }else {
        ALAssetsLibrary *assetsLibrary = [UZUIAssetsGroupViewController defaultAssetsLibrary];
        __weak typeof(self) weakSelf = self;
        ALAssetsLibraryGroupsEnumerationResultsBlock resultsBlock = ^(ALAssetsGroup *group, BOOL *stop) {
            if (group) {
                [group enumerateAssetsUsingBlock:^(ALAsset *result, NSUInteger index, BOOL *stop) {
                    if ([result.defaultRepresentation.url.absoluteString isEqualToString:path]) {
                        int duration = ceil([[result valueForProperty:ALAssetPropertyDuration] doubleValue]);
                        if (duration) {
                            [weakSelf sendResultEventWithCallbackId:duratinCbId dataDict:@{@"duration" : @(duration)} errDict:nil doDelete:YES];
                        }
                        stop = (BOOL *)YES;
                    }
                }];
            } else {
                stop = (BOOL *)YES;
            }
        };
        ALAssetsLibraryAccessFailureBlock failureBlock = ^(NSError *error) {
        };
        [assetsLibrary enumerateGroupsWithTypes:ALAssetsGroupAll
                                     usingBlock:resultsBlock
                                   failureBlock:failureBlock];
    }
}

#pragma mark -
#pragma mark  AssetsViewCallBackDelegate
#pragma mark -

- (void)previewCallback:(NSDictionary *)listDict {
    if (cbOpenId != -1) {
        NSDictionary *sendDict = [[NSDictionary alloc]initWithDictionary:listDict];
        [self sendResultEventWithCallbackId:cbOpenId dataDict:sendDict errDict:nil doDelete:NO];
    }
}

- (void)callBack:(NSDictionary *)listDict {
    if (cbOpenId != -1) {
        NSDictionary *sendDict = [[NSDictionary alloc]initWithDictionary:listDict];
        [self sendResultEventWithCallbackId:cbOpenId dataDict:sendDict errDict:nil doDelete:NO];
    }
}

- (NSString *)getPath:(NSString *)path {
    return [self getPathWithUZSchemeURL:path];
}

#pragma mark -
#pragma mark  Utility
#pragma mark -

- (void)loadDataSource:(NSString *)path {//加载本地相册里的数据
    @autoreleasepool {
        __block  NSMutableArray *all = [[NSMutableArray alloc] init];
        __block  NSMutableArray *pic = [[NSMutableArray alloc] init];
        __block  NSMutableArray *vid = [[NSMutableArray alloc] init];
        ALAssetsLibrary *assetsLibrary;
        assetsLibrary = [self.class defaultAssetsLibrary];
        [assetsLibrary enumerateGroupsWithTypes:ALAssetsGroupSavedPhotos usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
            [group enumerateAssetsUsingBlock:^(ALAsset *result, NSUInteger index, BOOL *stop) {
                NSString *type = [result valueForProperty:ALAssetPropertyType];
                if (result != nil) {
                    if (![all containsObject:result]) {
                        [all addObject:result];
                    }
                    if ([type isEqual:ALAssetTypePhoto] && ![pic containsObject:result]) {
                        [pic addObject:result];
                    }
                    if ([type isEqual:ALAssetTypeVideo] && ![vid containsObject:result]) {
                        [vid addObject:result];
                    }
                } else  {
                    NSString *type = [_scanDict stringValueForKey:@"type" defaultValue:@"all"];
                    NSArray *arr;
                    if ([type isEqualToString:@"all"]) {
                        arr = all;
                    } else if ([type isEqualToString:@"picture"]) {
                        arr = pic;
                    } else if ([type isEqualToString:@"video"]) {
                        arr = vid;
                    }
                    _allAry = [[NSMutableArray alloc] initWithArray:all];
                    _picAry = [[NSMutableArray alloc] initWithArray:pic];
                    _vidAry = [[NSMutableArray alloc] initWithArray:vid];
                    for (ALAsset *asset in arr) {
                        [self.assets addObject:asset];
                    }
                    [self sortDataSource:nil];
                }
            }];
        } failureBlock:^(NSError *error) {
            NSLog(@"Turbo___mediaScanner__error:%@",error);
        }];
    }
}

- (void)loadDataSourceInGroup:(NSString *)path {//加载本地相册里的数据
    @autoreleasepool {
        _allAry = [NSMutableArray array];
        _picAry = [NSMutableArray array];
        _vidAry = [NSMutableArray array];
        ALAssetsLibrary *assetsLibrary;
        assetsLibrary = [self.class defaultAssetsLibrary];
        [assetsLibrary enumerateGroupsWithTypes:ALAssetsGroupAll usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
            if (!group) {
                NSString *type = [_scanDict stringValueForKey:@"type" defaultValue:@"all"];
                NSArray *arr;
                if ([type isEqualToString:@"all"]) {
                    arr = _allAry;
                } else if ([type isEqualToString:@"picture"]) {
                    arr = _picAry;
                } else if ([type isEqualToString:@"video"]) {
                    arr = _vidAry;
                }
                for (ALAsset *asset in arr) {
                    [self.assets addObject:asset];
                }
                [self sortDataSource:nil];
            }
            NSString *groupname = [group valueForProperty:ALAssetsGroupPropertyName];
            [group enumerateAssetsUsingBlock:^(ALAsset *result, NSUInteger index, BOOL *stop) {
                NSString *type = [result valueForProperty:ALAssetPropertyType];
                if (result) {
                    //扩展属性
                    objc_setAssociatedObject(result, &extendKey, groupname, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [_allAry addObject:result];
                    if ([type isEqual:ALAssetTypePhoto]) {
                        [_picAry addObject:result];
                    }
                    if ([type isEqual:ALAssetTypeVideo]) {
                        [_vidAry addObject:result];
                    }
                }
            }];
        } failureBlock:^(NSError *error) {
            NSLog(@"Turbo___mediaScanner__error:%@",error);
        }];
    }
}

//排序
- (void)sortDataSource: (id)obj {
    capicity = [self.scanDict floatValueForKey:@"count" defaultValue:(int)self.assets.count];
    NSDictionary *sortInfo = [self.scanDict dictValueForKey:@"sort" defaultValue:@{}];
    NSString *keyStr = [sortInfo stringValueForKey:@"key" defaultValue:@"time"];
    NSString *orderStr = [sortInfo stringValueForKey:@"order" defaultValue:@"desc"];
    if (keyStr) {
        if ([keyStr isEqualToString:@"time"]) {
            NSArray *sortedArray = [self.assets sortedArrayUsingComparator:^(ALAsset *asset1,ALAsset *asset2) {
                NSDate *pictureDate1 = [asset1 valueForProperty:ALAssetPropertyDate];
                NSDate *pictureDate2 = [asset2 valueForProperty:ALAssetPropertyDate];
                NSDate *date = [pictureDate1 earlierDate:pictureDate2];
                if (pictureDate1 == date && [orderStr isEqualToString:@"asc"]) {//升序
                    return NSOrderedAscending;
                } else {
                    return NSOrderedDescending;
                }
            }];
            [self.assets removeAllObjects];
            for (ALAsset *asset in sortedArray) {
                [self.assets addObject:asset];
            }
        } else {
            NSArray *sortedArray;
            if ([orderStr isEqualToString:@"desc"]) {
                sortedArray = [self.assets sortedArrayUsingComparator:^( ALAsset *asset1,ALAsset *asset2) {
                    if (asset1.defaultRepresentation.size > asset2.defaultRepresentation.size) {
                        return NSOrderedDescending;
                    } else {
                        return NSOrderedAscending;
                    }
                }];
            } else {
                sortedArray = [self.assets sortedArrayUsingComparator:^( ALAsset *asset1,ALAsset *asset2) {
                    if (asset1.defaultRepresentation.size < asset2.defaultRepresentation.size) {
                        return NSOrderedAscending;
                    } else {
                        return NSOrderedDescending;
                    }
                }];
            }
        }
    }
    //创建一个线程，用来取指定页码和数量的照片数据
    NSThread *specifiedData = [[NSThread alloc] initWithTarget:self selector:@selector(getSpecifiedData:) object:nil];
    [specifiedData start];
    //创建一个线程,用来准备资源信息（将缩略图拷贝到临时文件夹下）
    NSThread *prepareData = [[NSThread alloc] initWithTarget:self selector:@selector(prepareScannData:) object:nil];
    [prepareData start];
}

//获取指定页码和数量的照片数据，并回调给scann或fetch
- (void)getSpecifiedData:(id)obj {
    NSMutableArray *callBackArr = [NSMutableArray array];
    for (int i = fetchPosition; i < capicity+fetchPosition; i++) {
        if (i >= _assets.count) {
            break;
        }
        ALAsset *result = self.assets[i];
        //资源类型  PNG MOV JPG
        NSString *filename = result.defaultRepresentation.filename;
        NSString *mimeType = [[[filename componentsSeparatedByString:@"."] lastObject] lowercaseString];
        //获取创建时间信息
        NSDate *pictureDate = [result valueForProperty:ALAssetPropertyDate];
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *strDate = [dateFormatter stringFromDate:pictureDate];
        //资源路径URL
        NSURL *assetUrls = result.defaultRepresentation.url;
        //资源缩略图URL
        UIImage *image = [UIImage imageWithCGImage:result.thumbnail];
        image = [self setNewSizeWithOriginImage:image toSize:thumbSize];
        //创建存放缩略图的文件
        NSString *imagePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *filePath = [imagePath  stringByAppendingPathComponent:@"UIMediaScanner"];
        if (![fileManager fileExistsAtPath:imagePath]) {
            [fileManager createDirectoryAtPath:imagePath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        [fileManager createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:nil];
        //建缩略图路径
        NSString *type  = [result valueForProperty:ALAssetPropertyType];
        NSString *imgPath;
        if ([type isEqualToString:ALAssetTypeVideo]) {
            NSRange ran = [filename rangeOfString:@"."];
            filename= [filename substringWithRange:NSMakeRange(0, ran.location+1)];
            imgPath = [filePath stringByAppendingString:[NSString stringWithFormat:@"/%@%@",filename,@"png"]];
        } else {
            imgPath = [filePath stringByAppendingString:[NSString stringWithFormat:@"/%@",filename]];
        }
        //将缩略图写入上步中创建的路径
        UIImage *img = [UIImage imageWithContentsOfFile:imgPath];
        if (!img) {
            NSData *data;
            if (UIImagePNGRepresentation(image) == nil) {
                data = UIImageJPEGRepresentation(image, 1);
            } else {
                data = UIImagePNGRepresentation(image);
            }
            if (data) {
                if ([type isEqualToString:ALAssetTypeVideo]) {
                    NSRange ran = [filename rangeOfString:@"."];
                    filename= [filename substringWithRange:NSMakeRange(0, ran.location+1)];
                    [fileManager createFileAtPath:imgPath contents:data attributes:nil];
                } else {
                    [fileManager createFileAtPath:imgPath contents:data attributes:nil];
                }
            }
        }
        //根据路径得到URL
        NSURL *thumbUrl =  [NSURL URLWithString:imgPath];
        //资源-照片大小   单位：Bytes
        NSNumber *size = [NSNumber numberWithLongLong:result.defaultRepresentation.size];
        if (result && assetUrls && size && result.thumbnail) {
            NSString *temp = [assetUrls absoluteString];
            NSString *temp1 = [thumbUrl absoluteString];
            NSMutableDictionary * ttt =[NSMutableDictionary dictionaryWithCapacity:3];
            
            if ([temp isKindOfClass:[NSString class]] && temp.length>0) {
                [ttt setObject:temp forKey:@"path"];
            }
            if ([temp1 isKindOfClass:[NSString class]] && temp1.length>0) {
                [ttt setObject:temp1 forKey:@"thumbPath"];
            }
            if ([mimeType isKindOfClass:[NSString class]] && mimeType.length>0) {
                [ttt setObject:mimeType forKey:@"suffix"];
            }
            if (size) {
                [ttt setObject:size forKey:@"size"];
            }
            if ([strDate isKindOfClass:[NSString class]] && strDate.length>0) {
                [ttt setObject:strDate forKey:@"time"];
            }
            NSString *associatedGroupName = (NSString *)objc_getAssociatedObject(result, &extendKey);
            if ([associatedGroupName isKindOfClass:[NSString class]] && associatedGroupName.length>0) {
                [ttt setObject:associatedGroupName forKey:@"groupName"];
            }
            [callBackArr addObject:ttt];
        }
    }
    fetchPosition += capicity;
    NSMutableDictionary *sendDict = [NSMutableDictionary dictionaryWithCapacity:1];
    [sendDict setObject:callBackArr forKey:@"list"];
    if (fecthCbId >= 0) {
        [self sendResultEventWithCallbackId:fecthCbId dataDict:sendDict errDict:nil doDelete:NO];
    } else {
        [sendDict setObject:[NSNumber numberWithInteger:_assets.count] forKey:@"total"];
        [self sendResultEventWithCallbackId:cbScannerId dataDict:sendDict errDict:nil doDelete:NO];
    }
    //获得该方法所在的线程
    NSThread *t = [NSThread currentThread];
    //关闭线程
    [t cancel];
}

//准备资源信息（将缩略图拷贝到临时文件夹下）
- (void)prepareScannData:(id)obj {
    if (_cBAll) {
        [_cBAll removeAllObjects];
    } else {
        _cBAll = [NSMutableArray arrayWithCapacity:1];
    }
    for (int i = 0; i < self.assets.count; i++) {
        if (i >= _assets.count) {
            break;
        }
        ALAsset *result = self.assets[i];
        //资源类型  PNG MOV JPG
        NSString *filename = result.defaultRepresentation.filename;
        NSString *mimeType = [[[filename componentsSeparatedByString:@"."] lastObject] lowercaseString];
        //获取创建时间信息
        NSDate *pictureDate = [result valueForProperty:ALAssetPropertyDate];
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *strDate = [dateFormatter stringFromDate:pictureDate];
        //资源路径URL
        NSURL *assetUrls = result.defaultRepresentation.url;
        //资源缩略图URL
        UIImage *image = [UIImage imageWithCGImage:result.thumbnail];
        image = [self setNewSizeWithOriginImage:image toSize:thumbSize];
        NSString *imagePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        //创建存放缩略图的文件
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *filePath = [imagePath  stringByAppendingPathComponent:@"UIMediaScanner"];
        if (![fileManager fileExistsAtPath:imagePath]) {
            [fileManager createDirectoryAtPath:imagePath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        [fileManager createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:nil];
        //建缩略图路径
        NSString *type  = [result valueForProperty:ALAssetPropertyType];
        NSString *imgPath;
        if ([type isEqualToString:ALAssetTypeVideo]) {
            NSRange ran = [filename rangeOfString:@"."];
            filename= [filename substringWithRange:NSMakeRange(0, ran.location+1)];
            imgPath = [filePath stringByAppendingString:[NSString stringWithFormat:@"/%@%@",filename,@"png"]];
        } else {
            imgPath = [filePath stringByAppendingString:[NSString stringWithFormat:@"/%@",filename]];
        }
        //将缩略图写入上步中创建的路径
        UIImage *img = [UIImage imageWithContentsOfFile:imgPath];
        if (!img) {
            NSData *data;
            if (UIImagePNGRepresentation(image) == nil) {
                data = UIImageJPEGRepresentation(image, 1);
            } else {
                data = UIImagePNGRepresentation(image);
            }
            if (data) {
                if ([type isEqualToString:ALAssetTypeVideo]) {
                    NSRange ran = [filename rangeOfString:@"."];
                    filename= [filename substringWithRange:NSMakeRange(0, ran.location+1)];
                    [fileManager createFileAtPath:imgPath contents:data attributes:nil];
                } else {
                    [fileManager createFileAtPath:imgPath contents:data attributes:nil];
                }
            }
        }
   
        //资源-照片大小   单位：Bytes
        NSNumber *size = [NSNumber numberWithLongLong:result.defaultRepresentation.size];
        if (result && assetUrls && result.thumbnail && imgPath) {
            NSString *temp = [assetUrls absoluteString];
            NSMutableDictionary * ttt =[NSMutableDictionary dictionaryWithCapacity:3];
            if ([temp isKindOfClass:[NSString class]] && temp.length>0) {
                [ttt setObject:temp forKey:@"path"];
            }
            if ([imgPath isKindOfClass:[NSString class]] && imgPath.length>0) {
                [ttt setObject:imgPath forKey:@"thumbPath"];
            }
            if ([mimeType isKindOfClass:[NSString class]] && mimeType.length>0) {
                [ttt setObject:mimeType forKey:@"suffix"];
            }
            if (size) {
                [ttt setObject:size forKey:@"size"];
            }
            if ([strDate isKindOfClass:[NSString class]] && strDate.length>0) {
                [ttt setObject:strDate forKey:@"time"];
            }
            NSString *associatedGroupName = (NSString *)objc_getAssociatedObject(result, &extendKey);
            if ([associatedGroupName isKindOfClass:[NSString class]] && associatedGroupName.length>0) {
                [ttt setObject:associatedGroupName forKey:@"groupName"];
            }
            [_cBAll addObject:ttt];
        }
    }
    preparedData = YES;
    //获得该方法所在的线程
    NSThread *t = [NSThread currentThread];
    //关闭线程
    [t cancel];
}

- (void)fetchCallBack {//遍历接口回调
    NSMutableArray *callBackArr = [NSMutableArray array];
    for (int i = fetchPosition; i < capicity+fetchPosition; i++) {
        if (i >= _cBAll.count) {
            break;
        }
        [callBackArr addObject:_cBAll[i]];
    }
    fetchPosition += capicity;
    NSMutableDictionary *sendDict = [NSMutableDictionary dictionaryWithCapacity:1];
    [sendDict setObject:callBackArr forKey:@"list"];
    [self sendResultEventWithCallbackId:fecthCbId dataDict:sendDict errDict:nil doDelete:YES];
}

+ (ALAssetsLibrary *)defaultAssetsLibrary {
    static dispatch_once_t pred = 0;
    static ALAssetsLibrary *library = nil;
    dispatch_once(&pred, ^{
        library = [[ALAssetsLibrary alloc] init];
    });
    return library;
}

- (NSString *)typeForImageData:(NSString *)data {
    NSArray *pathSpe = [data componentsSeparatedByString:@"="];
    NSString *type = [pathSpe lastObject];
    return [NSString stringWithFormat:@"%@", type];
    //uint8_t c;
    //[data getBytes:&c length:1];
    //switch (c) {
    //    case 0xFF:
    //        return @".jpg";
    //        
    //    case 0x89:
    //        return @".png";
    //        
    //    case 0x47:
    //        return @".gif";
    //        
    //    case 0x49:
    //    case 0x4D:
    //        return @".tiff";
    //}
    //return @".png";
}

- (NSString *)md5:(NSString *)str{
    const char *cStr = [str UTF8String];
    unsigned char result[16];
    CC_MD5( cStr, (unsigned)strlen(cStr), result );
    return [NSString stringWithFormat:
            @"%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]
            ];
    
}

- (UIImage *)imageCorrectedForCaptureOrientation:(UIImage *)anImage UIImageOrientation:(UIImageOrientation)ImageOrientation {//旋转图片
    if (ImageOrientation == UIImageOrientationUp) {
        return anImage;
    }
    
    float rotation_radians = 0;
    bool perpendicular = false;
    switch (ImageOrientation) {
        case UIImageOrientationDown :
        case UIImageOrientationDownMirrored :
            // don't be scared of radians, if you're reading this, you're good at math
            rotation_radians = M_PI;
            break;
            
        case UIImageOrientationRight:
        case UIImageOrientationRightMirrored:
            rotation_radians = M_PI_2;
            perpendicular = true;
            break;
            
        case UIImageOrientationLeft:
        case UIImageOrientationLeftMirrored:
            rotation_radians = -M_PI_2;
            perpendicular = true;
            break;
            
        default:
            break;
    }
    UIGraphicsBeginImageContext(CGSizeMake(anImage.size.width, anImage.size.height));
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, anImage.size.width / 2, anImage.size.height / 2);
    CGContextRotateCTM(context, rotation_radians);
    CGContextScaleCTM(context, 1.0, -1.0);
    float width = perpendicular ? anImage.size.height : anImage.size.width;
    float height = perpendicular ? anImage.size.width : anImage.size.height;
    CGContextDrawImage(context, CGRectMake(-width / 2, -height / 2, width, height), [anImage CGImage]);
    if (perpendicular) {
        CGContextTranslateCTM(context, -anImage.size.height / 2, -anImage.size.width / 2);
    }
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

#pragma mark - classify

- (void)classify:(NSDictionary *)paramsDict_ {
    BOOL classifyId = [paramsDict_ integerValueForKey:@"classify" defaultValue:NO];
    BOOL isRotation = [paramsDict_ boolValueForKey:@"rotation" defaultValue:false];
    BOOL showPreview = [paramsDict_ boolValueForKey:@"showPreview" defaultValue:NO];
    BOOL showBrowser = [paramsDict_ boolValueForKey:@"showBrowser" defaultValue:NO];
    if (classifyId) {
        UZUIAssetsGroupViewController *assetGroupVc = [[UZUIAssetsGroupViewController alloc]init];
        assetGroupVc.showBrowser = showBrowser;
        assetGroupVc.showPreview = showPreview;
        assetGroupVc.paramsDict = paramsDict_;
        assetGroupVc.delegate = self; 
        UZUIAssetNavigationController *assetGroupNavi = [[UZUIAssetNavigationController alloc]initWithRootViewController:assetGroupVc];
        assetGroupNavi.isRotation = isRotation;
        [self.viewController presentViewController:assetGroupNavi animated:YES completion:^{}];
    } else {
        UZUIAssetsViewController *assetVC = [[UZUIAssetsViewController alloc] initWithDict:paramsDict_];
        assetVC.showPreview = showPreview;
        assetVC.showBrowser = showBrowser;
        assetVC.delegate = self;
        //[self.viewController.navigationController pushViewController:assetVC animated:YES];
        UZUIAssetNavigationController *navi = [[UZUIAssetNavigationController alloc] initWithRootViewController:assetVC];
        navi.isRotation = isRotation;
        [self.viewController presentViewController:navi animated:YES completion:^{}];
    }
}

#pragma mark - 修改 thumbnail 大小

- (UIImage *)setNewSizeWithOriginImage:(UIImage *)oriImage toSize:(CGSize)newSize {
    UIGraphicsBeginImageContext(newSize);
    [oriImage drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

#pragma mark - AssetsLibrary -

- (void)save:(UIImage *)img imagePath:(NSString *)path cbId:(NSInteger)cbId {//保存指定图片到临时位置并回调改位置路径
    UIImage *saveImg = img;
    NSString *name = [self md5:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *filePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/UIMediaScanner"];
    if (![fileManager fileExistsAtPath:filePath]) {        //创建路径
        [fileManager createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSData *data = nil;
    NSString *type = [self typeForImageData:path];
    if ([type isEqualToString:@"JPG"]) {
        data = UIImageJPEGRepresentation(saveImg, 1.0);
    } else if ([type isEqualToString:@"PNG"]) {
        data = UIImagePNGRepresentation(saveImg);
    } else {
        data = UIImageJPEGRepresentation(saveImg, 1.0);
    }
    NSString *imgPath = [filePath stringByAppendingString:[NSString stringWithFormat:@"/%@.%@",name,type]];
    //创建文件
    if (data) {
        [fileManager createFileAtPath:imgPath contents:data attributes:nil];
    }
    //回到主线程
    dispatch_async(dispatch_get_main_queue(), ^{
        [self sendResultEventWithCallbackId:cbId dataDict:[NSDictionary dictionaryWithObjectsAndKeys:imgPath,@"path", nil] errDict:nil doDelete:YES];
    });
}

- (NSString *)localPathForAssetLibraryPath:(NSString *)assetsLibraryPath {
    NSString *localPath = nil;
    ALAssetRepresentation *assetRepresentation = [self assetRepresentationForPath:assetsLibraryPath];
    long long size = [assetRepresentation size];
    if (size > 0) {
        NSString *fileName = [assetRepresentation filename];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *filePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/UIMediaScanner"];
        if (![fileManager fileExistsAtPath:filePath]) {        //创建路径
            [fileManager createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *name = [self md5:assetsLibraryPath];
        NSString *mimeType = [[[fileName componentsSeparatedByString:@"."] lastObject] lowercaseString];
        localPath = [NSString stringWithFormat:@"%@/%@.%@",filePath,name,mimeType];
        
        //localPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
        NSOutputStream *outPutStream = [[NSOutputStream alloc] initToFileAtPath:localPath append:NO];
        [outPutStream open];
        
        NSUInteger partitionSize = 1024*256;
        NSUInteger mod = size%partitionSize;
        long long count = size/partitionSize+(mod==0?0:1);
        for (int i=0; i<count; i++) {
            Byte buffer[1024*256];
            NSUInteger length = i==count-1?(mod==0?partitionSize:mod):partitionSize;
            NSUInteger bufferSize = [assetRepresentation getBytes:buffer fromOffset:i*partitionSize length:length error:nil];
            
            if (bufferSize > 0) {
                [outPutStream write:buffer maxLength:bufferSize];
            }
        }
        [outPutStream close];
    }
    return localPath;
}

- (ALAssetRepresentation *)assetRepresentationForPath:(NSString *)assetsLibraryPath {
    __block ALAssetRepresentation *assetRepresentation = nil;
    if ([assetsLibraryPath hasPrefix:@"assets-library://"]) {
        __block BOOL finished = NO;
        
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            ALAssetsLibraryAssetForURLResultBlock resultBlock = ^(ALAsset *asset) {
                if (asset) {
                    assetRepresentation = [asset defaultRepresentation];
                }
                finished = YES;
            };
            
            ALAssetsLibraryAccessFailureBlock failureBlock = ^(NSError *error) {
                finished = YES;
            };
            
            ALAssetsLibrary *assetsLibrary = [self defaultAssetsLibrary];
            [assetsLibrary assetForURL:[NSURL URLWithString:assetsLibraryPath] resultBlock:resultBlock failureBlock:failureBlock];
        });
        
        while (!finished) {
            [[NSRunLoop currentRunLoop] runMode:NSRunLoopCommonModes beforeDate:[NSDate distantFuture]];
        }
    }
    return assetRepresentation;
}

- (ALAssetsLibrary *)defaultAssetsLibrary {
    static dispatch_once_t pred = 0;
    static ALAssetsLibrary *library = nil;
    dispatch_once(&pred, ^{
        library = [[ALAssetsLibrary alloc] init];
    });
    return library;
}
@end
