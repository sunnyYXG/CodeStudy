#import "AFURLSessionManager.h"
#import <objc/runtime.h>

#ifndef NSFoundationVersionNumber_iOS_8_0
#define NSFoundationVersionNumber_With_Fixed_5871104061079552_bug 1140.11
#else
#define NSFoundationVersionNumber_With_Fixed_5871104061079552_bug NSFoundationVersionNumber_iOS_8_0
#endif

#pragma mark - 下面两个方法用于安全的创建一个dataTask
//返回一个串行的dispat_queue_t
static dispatch_queue_t url_session_manager_creation_queue() {
    static dispatch_queue_t af_url_session_manager_creation_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_creation_queue = dispatch_queue_create("com.alamofire.networking.session.manager.creation", DISPATCH_QUEUE_SERIAL);
    });

    return af_url_session_manager_creation_queue;
}
//用于处理ios8下面的系统bug
static void url_session_manager_create_task_safely(dispatch_block_t block) {
    if (NSFoundationVersionNumber < NSFoundationVersionNumber_With_Fixed_5871104061079552_bug) {
        // Fix of bug
        // Open Radar:http://openradar.appspot.com/radar?id=5871104061079552 (status: Fixed in iOS8)
        // Issue about:https://github.com/AFNetworking/AFNetworking/issues/2093
        dispatch_sync(url_session_manager_creation_queue(), block);
    } else {
        block();
    }
}

//dispatch_queue_t和dispatch_group_t主要是用于在一个Task结束以后。处理获取的数据的时候用到
static dispatch_queue_t url_session_manager_processing_queue() {
    static dispatch_queue_t af_url_session_manager_processing_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_processing_queue = dispatch_queue_create("com.alamofire.networking.session.manager.processing", DISPATCH_QUEUE_CONCURRENT);
    });

    return af_url_session_manager_processing_queue;
}

static dispatch_group_t url_session_manager_completion_group() {
    static dispatch_group_t af_url_session_manager_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_completion_group = dispatch_group_create();
    });

    return af_url_session_manager_completion_group;
}

#pragma mark - 通知的定义
NSString * const AFNetworkingTaskDidResumeNotification = @"com.alamofire.networking.task.resume";
NSString * const AFNetworkingTaskDidCompleteNotification = @"com.alamofire.networking.task.complete";
NSString * const AFNetworkingTaskDidSuspendNotification = @"com.alamofire.networking.task.suspend";
NSString * const AFURLSessionDidInvalidateNotification = @"com.alamofire.networking.session.invalidate";
NSString * const AFURLSessionDownloadTaskDidFailToMoveFileNotification = @"com.alamofire.networking.session.download.file-manager-error";
#pragma mark - 用于拼接处理返回数据的时候对应的dictory的key
NSString * const AFNetworkingTaskDidCompleteSerializedResponseKey = @"com.alamofire.networking.task.complete.serializedresponse";
NSString * const AFNetworkingTaskDidCompleteResponseSerializerKey = @"com.alamofire.networking.task.complete.responseserializer";
NSString * const AFNetworkingTaskDidCompleteResponseDataKey = @"com.alamofire.networking.complete.finish.responsedata";
NSString * const AFNetworkingTaskDidCompleteErrorKey = @"com.alamofire.networking.task.complete.error";
NSString * const AFNetworkingTaskDidCompleteAssetPathKey = @"com.alamofire.networking.task.complete.assetpath";
//所对应的名字
static NSString * const AFURLSessionManagerLockName = @"com.alamofire.networking.session.manager.lock";
//iOS7下面创建Task失败的bug 最多可以创建多少次
static NSUInteger const AFMaximumNumberOfAttemptsToRecreateBackgroundSessionUploadTask = 3;

static void * AFTaskStateChangedContext = &AFTaskStateChangedContext;
#pragma mark 接口文件定义的各种Block的类型定义
typedef void (^AFURLSessionDidBecomeInvalidBlock)(NSURLSession *session, NSError *error);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);

typedef NSURLRequest * (^AFURLSessionTaskWillPerformHTTPRedirectionBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionTaskDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);
typedef void (^AFURLSessionDidFinishEventsForBackgroundURLSessionBlock)(NSURLSession *session);

typedef NSInputStream * (^AFURLSessionTaskNeedNewBodyStreamBlock)(NSURLSession *session, NSURLSessionTask *task);
typedef void (^AFURLSessionTaskDidSendBodyDataBlock)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend);
typedef void (^AFURLSessionTaskDidCompleteBlock)(NSURLSession *session, NSURLSessionTask *task, NSError *error);

typedef NSURLSessionResponseDisposition (^AFURLSessionDataTaskDidReceiveResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response);
typedef void (^AFURLSessionDataTaskDidBecomeDownloadTaskBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask);
typedef void (^AFURLSessionDataTaskDidReceiveDataBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data);
typedef NSCachedURLResponse * (^AFURLSessionDataTaskWillCacheResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse);

typedef NSURL * (^AFURLSessionDownloadTaskDidFinishDownloadingBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location);
typedef void (^AFURLSessionDownloadTaskDidWriteDataBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);
typedef void (^AFURLSessionDownloadTaskDidResumeBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes);
typedef void (^AFURLSessionTaskProgressBlock)(NSProgress *);

typedef void (^AFURLSessionTaskCompletionHandler)(NSURLResponse *response, id responseObject, NSError *error);


#pragma mark - 这个类实现了Task的NSUrlSessionTaskDelegate、NSURLSessionDataDelegate、NSURLSessionDownloadDelegate三个代理方法，主要是为了处理上传或者下载的进度、以及各种状态下block的调用，和task状态改变的通知

/**
 AFURLSessionManager 通过对task设置一个AFURLSessionManagerTaskDelegate代理来处置繁琐复杂的请求进度管理，从而降低啦代码的负责度，是代理模式的一个很好的实践
 */
@interface AFURLSessionManagerTaskDelegate : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, weak) AFURLSessionManager *manager;
//英语存储task下载过程中的数据
@property (nonatomic, strong) NSMutableData *mutableData;
//存储上传下载的进度
@property (nonatomic, strong) NSProgress *uploadProgress;
@property (nonatomic, strong) NSProgress *downloadProgress;
@property (nonatomic, copy) NSURL *downloadFileURL;
//task对应的代理block
@property (nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (nonatomic, copy) AFURLSessionTaskProgressBlock uploadProgressBlock;
@property (nonatomic, copy) AFURLSessionTaskProgressBlock downloadProgressBlock;
@property (nonatomic, copy) AFURLSessionTaskCompletionHandler completionHandler;
@end

@implementation AFURLSessionManagerTaskDelegate

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    //用于存储task下载过程中的数据
    self.mutableData = [NSMutableData data];
    //存储上传和下载的进度
    self.uploadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    self.uploadProgress.totalUnitCount = NSURLSessionTransferSizeUnknown;

    self.downloadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    self.downloadProgress.totalUnitCount = NSURLSessionTransferSizeUnknown;
    return self;
}

#pragma mark - NSProgress Tracking

- (void)setupProgressForTask:(NSURLSessionTask *)task {
    /*
     上传的totalUnitCount就对应期望发送(send)的数据大小，下载任务的就对应期望接收(receive)的数据大小。
     
     接着就是设置这两个NSProgress对应的cancel、pause和resume这三个状态，正好对应session task的cancel、suspend和resume三个状态
     */
    
    __weak __typeof__(task) weakTask = task;

    self.uploadProgress.totalUnitCount = task.countOfBytesExpectedToSend;
    self.downloadProgress.totalUnitCount = task.countOfBytesExpectedToReceive;
    
    /*
     下面设置了uploadProgress和downloadProgress的三个属性：cancel/pause/resume。正好对应session task的cancel/pause/resume三个状态。也就是说进度progress的数据来源于实际上由session task来驱动
     */
    //当uploadProgress对象取消的时候 取消task
    [self.uploadProgress setCancellable:YES];
    [self.uploadProgress setCancellationHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask cancel];
    }];
    //当uploadProgress对象挂起的时候 挂起task
    [self.uploadProgress setPausable:YES];
    [self.uploadProgress setPausingHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask suspend];
    }];
    //当uploadProgress对象重启的时候 重启task
    if ([self.uploadProgress respondsToSelector:@selector(setResumingHandler:)]) {
        [self.uploadProgress setResumingHandler:^{
            __typeof__(weakTask) strongTask = weakTask;
            [strongTask resume];
        }];
    }

    [self.downloadProgress setCancellable:YES];
    [self.downloadProgress setCancellationHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask cancel];
    }];
    [self.downloadProgress setPausable:YES];
    [self.downloadProgress setPausingHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask suspend];
    }];

    if ([self.downloadProgress respondsToSelector:@selector(setResumingHandler:)]) {
        [self.downloadProgress setResumingHandler:^{
            __typeof__(weakTask) strongTask = weakTask;
            [strongTask resume];
        }];
    }

    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))
              options:NSKeyValueObservingOptionNew
              context:NULL];
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))
              options:NSKeyValueObservingOptionNew
              context:NULL];

    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesSent))
              options:NSKeyValueObservingOptionNew
              context:NULL];
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToSend))
              options:NSKeyValueObservingOptionNew
              context:NULL];

    // 给两个progress添加KVO监听 NSProgress的fractionCompleted属性（任务已经完成的比例，取值为0~1）
    //更新progress的进度来获取Task的进度。fractionCompleted方法在请求过程中多次执行。
    [self.downloadProgress addObserver:self
                            forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                               options:NSKeyValueObservingOptionNew
                               context:NULL];
    [self.uploadProgress addObserver:self
                          forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                             options:NSKeyValueObservingOptionNew
                             context:NULL];
}

- (void)cleanUpProgressForTask:(NSURLSessionTask *)task {
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))];
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))];
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesSent))];
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToSend))];
    [self.downloadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
    [self.uploadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    if ([object isKindOfClass:[NSURLSessionTask class]] || [object isKindOfClass:[NSURLSessionDownloadTask class]]) {
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesReceived))]) {
            self.downloadProgress.completedUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))]) {
            self.downloadProgress.totalUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesSent))]) {
            self.uploadProgress.completedUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesExpectedToSend))]) {
            self.uploadProgress.totalUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        }
    }
    else if ([object isEqual:self.downloadProgress]) {
        //更新下载的进度block
        if (self.downloadProgressBlock) {
            self.downloadProgressBlock(object);
        }
    }
    else if ([object isEqual:self.uploadProgress]) {
        //更行上传的进度block
        if (self.uploadProgressBlock) {
            self.uploadProgressBlock(object);
        }
    }
}

#pragma mark - NSURLSessionTaskDelegate
//AFURLSessionManagerTaskDelegate里面的这个代理方法实现对数据的具体处理。
- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
    //获取task对应的manager对象
    __strong AFURLSessionManager *manager = self.manager;

    //要封装的responseObject对象
    __block id responseObject = nil;

    __block NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[AFNetworkingTaskDidCompleteResponseSerializerKey] = manager.responseSerializer;

    //Performance Improvement from #2672
    //返回的数据
    NSData *data = nil;
    if (self.mutableData) {
        data = [self.mutableData copy];
        //We no longer need the reference, so nil it out to gain back some memory.
        self.mutableData = nil;
    }

    //如果是downloadTask 则封装downloadFileURL
    if (self.downloadFileURL) {
        userInfo[AFNetworkingTaskDidCompleteAssetPathKey] = self.downloadFileURL;
    } else if (data) {
        //如果是其他task  封装data
        userInfo[AFNetworkingTaskDidCompleteResponseDataKey] = data;
    }

    //有错封装
    if (error) {
        userInfo[AFNetworkingTaskDidCompleteErrorKey] = error;

        dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
            //如果task有completionHandler 调用下面这个block
            if (self.completionHandler) {
                self.completionHandler(task.response, responseObject, error);
            }

            //发送一个指定task结束的通知
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
            });
        });
    } else {
        //正确数据封装
        //在一个并行的dispatch_queue_t对象里面进行异步处理
        dispatch_async(url_session_manager_processing_queue(), ^{
            NSError *serializationError = nil;
            //封装responseObject
            responseObject = [manager.responseSerializer responseObjectForResponse:task.response data:data error:&serializationError];

            if (self.downloadFileURL) {
                responseObject = self.downloadFileURL;
            }

            if (responseObject) {
                userInfo[AFNetworkingTaskDidCompleteSerializedResponseKey] = responseObject;
            }

            if (serializationError) {
                userInfo[AFNetworkingTaskDidCompleteErrorKey] = serializationError;
            }

            dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
                //如果task又完成的block 则调用
                if (self.completionHandler) {
                    self.completionHandler(task.response, responseObject, serializationError);
                }

                //发送通知
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
                });
            });
        });
    }
#pragma clang diagnostic pop
}

#pragma mark - NSURLSessionDataTaskDelegate

- (void)URLSession:(__unused NSURLSession *)session
          dataTask:(__unused NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    [self.mutableData appendData:data];
}

#pragma mark - NSURLSessionDownloadTaskDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    NSError *fileManagerError = nil;
    self.downloadFileURL = nil;

    if (self.downloadTaskDidFinishDownloading) {
        self.downloadFileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (self.downloadFileURL) {
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:self.downloadFileURL error:&fileManagerError];

            if (fileManagerError) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:fileManagerError.userInfo];
            }
        }
    }
}

@end

#pragma mark -

/**
 *  A workaround for issues related to key-value observing the `state` of an `NSURLSessionTask`.
 *
 *  See:
 *  - https://github.com/AFNetworking/AFNetworking/issues/1477
 *  - https://github.com/AFNetworking/AFNetworking/issues/2638
 *  - https://github.com/AFNetworking/AFNetworking/pull/2702
 */
#pragma mark - 通过runtime向一个类中添加方法 并且swizzle方法
/**
 交换theClass类的originalSelector和swizzledSelector的实现

 @param theClass 类
 @param originalSelector 方法一
 @param swizzledSelector 方法二
 */
static inline void af_swizzleSelector(Class theClass, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(theClass, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(theClass, swizzledSelector);
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

/**
 动态给一个类添加方法

 @param theClass 类
 @param selector 方法名字
 @param method 方法体
 @return bool
 */
static inline BOOL af_addMethod(Class theClass, SEL selector, Method method) {
    return class_addMethod(theClass, selector,  method_getImplementation(method),  method_getTypeEncoding(method));
}

static NSString * const AFNSURLSessionTaskDidResumeNotification  = @"com.alamofire.networking.nsurlsessiontask.resume";
static NSString * const AFNSURLSessionTaskDidSuspendNotification = @"com.alamofire.networking.nsurlsessiontask.suspend";

/**
 AFURLSessionManager通过私有类_AFURLSessionTaskSwizzling来修改iOS7和iOS8系统上面不同。是对于方法swizzle的一个成功和完整的实践。
 */
@interface _AFURLSessionTaskSwizzling : NSObject

@end
#pragma mark - _AFURLSessionTaskSwizzling私有类说明
/**
 在iOS7和iOS8及以上的系统中 NSURLSessionTak的具体实现是不同的 目前的不同之处有：
 1：NSURLSessionTask是一个类簇 所以我们初始化一个task的时候 我们并不知道初始化的是哪个子类
 2：简单的通过[NSURLSessionTask class]并不会起作用，必须通过NSURLSession创建一个task对象 然后获取他所在的类
 3：iOS7中 下面的代码中localDataTask对象的继承关系是__NSCFLocalDataTask -> __NSCFLocalSessionTask ->__NSCFSessionTask
 4：iOS8及以上系统中 下面的代码中localDataTask对象的继承关系是__NSCFLocalDataTask -> __NSCFLocalSessionTask ->NSURLSessionTask
 5：在iOS7中 下面的__NSCFLocalSessionTask和__NSCFURLSessionTask实现了resume和suspend方法 同事最重要的是他不调用父类的实现，但是在iOS8下 只有NSURLSessionTask实现啦resume和suspend。所以在iOS7的环境下，我们需要想办法让resume和suspend调用NSURLSessionTask的具体实现

 */

@implementation _AFURLSessionTaskSwizzling

+ (void)load {
    /**
     WARNING: Trouble Ahead
     https://github.com/AFNetworking/AFNetworking/pull/2702
     */

    if (NSClassFromString(@"NSURLSessionTask")) {
        /**
         iOS 7 and iOS 8 differ in NSURLSessionTask implementation, which makes the next bit of code a bit tricky.
         Many Unit Tests have been built to validate as much of this behavior has possible.
         Here is what we know:
            - NSURLSessionTasks are implemented with class clusters, meaning the class you request from the API isn't actually the type of class you will get back.
            - Simply referencing `[NSURLSessionTask class]` will not work. You need to ask an `NSURLSession` to actually create an object, and grab the class from there.
            - On iOS 7, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `__NSCFURLSessionTask`.
            - On iOS 8, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `NSURLSessionTask`.
            - On iOS 7, `__NSCFLocalSessionTask` and `__NSCFURLSessionTask` are the only two classes that have their own implementations of `resume` and `suspend`, and `__NSCFLocalSessionTask` DOES NOT CALL SUPER. This means both classes need to be swizzled.
            - On iOS 8, `NSURLSessionTask` is the only class that implements `resume` and `suspend`. This means this is the only class that needs to be swizzled.
            - Because `NSURLSessionTask` is not involved in the class hierarchy for every version of iOS, its easier to add the swizzled methods to a dummy class and manage them there.
        
         Some Assumptions:
            - No implementations of `resume` or `suspend` call super. If this were to change in a future version of iOS, we'd need to handle it.
            - No background task classes override `resume` or `suspend`
         
         The current solution:
            1) Grab an instance of `__NSCFLocalDataTask` by asking an instance of `NSURLSession` for a data task.
            2) Grab a pointer to the original implementation of `af_resume`
            3) Check to see if the current class has an implementation of resume. If so, continue to step 4.
            4) Grab the super class of the current class.
            5) Grab a pointer for the current class to the current implementation of `resume`.
            6) Grab a pointer for the super class to the current implementation of `resume`.
            7) If the current class implementation of `resume` is not equal to the super class implementation of `resume` AND the current implementation of `resume` is not equal to the original implementation of `af_resume`, THEN swizzle the methods
            8) Set the current class to the super class, and repeat steps 3-8
         */
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSURLSession * session = [NSURLSession sessionWithConfiguration:configuration];
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull"
        //初始化一个dataTask对象
        NSURLSessionDataTask *localDataTask = [session dataTaskWithURL:nil];
#pragma clang diagnostic pop
        //获取af_resume这个方法的实现
        IMP originalAFResumeIMP = method_getImplementation(class_getInstanceMethod([self class], @selector(af_resume)));
        //获取dataTask的具体类
        Class currentClass = [localDataTask class];
        //如果父类有resume方法 则改变方法的具体实现
        while (class_getInstanceMethod(currentClass, @selector(resume))) {
            Class superClass = [currentClass superclass];
            //找到类和父类的resume方法实现
            IMP classResumeIMP = method_getImplementation(class_getInstanceMethod(currentClass, @selector(resume)));
            IMP superclassResumeIMP = method_getImplementation(class_getInstanceMethod(superClass, @selector(resume)));
            if (classResumeIMP != superclassResumeIMP &&
                originalAFResumeIMP != classResumeIMP) {
                //添加方法 然后交换方法的实现
                [self swizzleResumeAndSuspendMethodForClass:currentClass];
            }
            currentClass = [currentClass superclass];
        }
        
        [localDataTask cancel];
        [session finishTasksAndInvalidate];
    }
}

/**
 主要是实现为一个类添加方法 并且交换‘添加方法’和‘原来方法’的实现
 @param theClass 要操作的类
 */
+ (void)swizzleResumeAndSuspendMethodForClass:(Class)theClass {
    Method afResumeMethod = class_getInstanceMethod(self, @selector(af_resume));
    Method afSuspendMethod = class_getInstanceMethod(self, @selector(af_suspend));

    //为theClass类添加方法af_resume
    if (af_addMethod(theClass, @selector(af_resume), afResumeMethod)) {
        //交换dataTask的resume和af_resume方法的实现
        af_swizzleSelector(theClass, @selector(resume), @selector(af_resume));
    }

    //为theClass类添加方法af_suspend
    if (af_addMethod(theClass, @selector(af_suspend), afSuspendMethod)) {
        //交换dataTask的suspend和af_suspend方法的实现
        af_swizzleSelector(theClass, @selector(suspend), @selector(af_suspend));
    }
}

- (NSURLSessionTaskState)state {
    NSAssert(NO, @"State method should never be called in the actual dummy class");
    return NSURLSessionTaskStateCanceling;
}

/**
 在iOS7下 `NSURLSessionDataTask`调用resume方法其实就是执行`af_resume`的具体实现。
 */
- (void)af_resume {
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    //这里其实调用的是dataTask的resume实现
    [self af_resume];
    
    if (state != NSURLSessionTaskStateRunning) {
        //这里的self就是‘NSURLSessionDataTask’对象
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidResumeNotification object:self];
    }
}
/**
 在iOS7下面，`NSURLSessionDataTask`调用suspend方法其实就是执行`af_suspend`的具体实现。
 */
- (void)af_suspend {
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    [self af_suspend];
    
    if (state != NSURLSessionTaskStateSuspended) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidSuspendNotification object:self];
    }
}
@end

#pragma mark -

@interface AFURLSessionManager ()
@property (readwrite, nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
@property (readwrite, nonatomic, strong) NSOperationQueue *operationQueue;
@property (readwrite, nonatomic, strong) NSURLSession *session;
@property (readwrite, nonatomic, strong) NSMutableDictionary *mutableTaskDelegatesKeyedByTaskIdentifier;
@property (readonly, nonatomic, copy) NSString *taskDescriptionForSessionTasks;
@property (readwrite, nonatomic, strong) NSLock *lock;
@property (readwrite, nonatomic, copy) AFURLSessionDidBecomeInvalidBlock sessionDidBecomeInvalid;
@property (readwrite, nonatomic, copy) AFURLSessionDidReceiveAuthenticationChallengeBlock sessionDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLSessionDidFinishEventsForBackgroundURLSessionBlock didFinishEventsForBackgroundURLSession;
@property (readwrite, nonatomic, copy) AFURLSessionTaskWillPerformHTTPRedirectionBlock taskWillPerformHTTPRedirection;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidReceiveAuthenticationChallengeBlock taskDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLSessionTaskNeedNewBodyStreamBlock taskNeedNewBodyStream;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidSendBodyDataBlock taskDidSendBodyData;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidCompleteBlock taskDidComplete;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveResponseBlock dataTaskDidReceiveResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidBecomeDownloadTaskBlock dataTaskDidBecomeDownloadTask;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveDataBlock dataTaskDidReceiveData;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskWillCacheResponseBlock dataTaskWillCacheResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidWriteDataBlock downloadTaskDidWriteData;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidResumeBlock downloadTaskDidResume;
@end

@implementation AFURLSessionManager

- (instancetype)init {
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (!configuration) {
        configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    }

    self.sessionConfiguration = configuration;
    //初始化NSURLSession的task代理方法执行的队列
    //关键点是task的代理执行的queue一次性只能执行一个task，这样就避免啦task的代理方法执行的混乱
    self.operationQueue = [[NSOperationQueue alloc] init];
    self.operationQueue.maxConcurrentOperationCount = 1;
    //初始化NSURLSession对象 也是最核心的对象
    self.session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:self.operationQueue];
    //初始化response 默认JSON
    self.responseSerializer = [AFJSONResponseSerializer serializer];
    //制定https处理的安全策略 AFSecurityPolicy 是 AFNetworking 用来保证 HTTP 请求安全的类，它被 AFURLSessionManager 持有
    self.securityPolicy = [AFSecurityPolicy defaultPolicy];

#if !TARGET_OS_WATCH
    //初始化网络状态监听属性
    self.reachabilityManager = [AFNetworkReachabilityManager sharedManager];
#endif
    // 初始化用来存放 task 与 他的AFURLSessionManagerTaskDelegate 代理对象 的字典
    self.mutableTaskDelegatesKeyedByTaskIdentifier = [[NSMutableDictionary alloc] init];

    self.lock = [[NSLock alloc] init];
    self.lock.name = AFURLSessionManagerLockName;

    //遍历所管理的session的task 给每个已有的task设置一个delegate 获取NSURLSession所有的网络任务，并执行回调处理
    /**
     获取session正在执行的所有task 同时为每一个task添加AFURLSessionManagerTaskDelegate代理对象 这个代理对象主要用于管理uploadTask和downloadTask的进度管理。并且task执行完以后调用相应的block 同时发送对应的notification对象 实现对task数据或者状态改变的检测
     */
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionDataTask *task in dataTasks) {
            [self addDelegateForDataTask:task uploadProgress:nil downloadProgress:nil completionHandler:nil];
        }

        for (NSURLSessionUploadTask *uploadTask in uploadTasks) {
            [self addDelegateForUploadTask:uploadTask progress:nil completionHandler:nil];
        }

        for (NSURLSessionDownloadTask *downloadTask in downloadTasks) {
            [self addDelegateForDownloadTask:downloadTask progress:nil destination:nil completionHandler:nil];
        }
    }];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -

- (NSString *)taskDescriptionForSessionTasks {
    return [NSString stringWithFormat:@"%p", self];
}

- (void)taskDidResume:(NSNotification *)notification {
    NSURLSessionTask *task = notification.object;
    if ([task respondsToSelector:@selector(taskDescription)]) {
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidResumeNotification object:task];
            });
        }
    }
}

- (void)taskDidSuspend:(NSNotification *)notification {
    NSURLSessionTask *task = notification.object;
    if ([task respondsToSelector:@selector(taskDescription)]) {
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidSuspendNotification object:task];
            });
        }
    }
}

#pragma mark -

- (AFURLSessionManagerTaskDelegate *)delegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    AFURLSessionManagerTaskDelegate *delegate = nil;
    [self.lock lock];
    delegate = self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)];
    [self.lock unlock];

    return delegate;
}

- (void)setDelegate:(AFURLSessionManagerTaskDelegate *)delegate
            forTask:(NSURLSessionTask *)task
{
    NSParameterAssert(task);
    NSParameterAssert(delegate);

//    加锁确保字典的线程安全
    [self.lock lock];
    // 将AF delegate放入以taskIdentifier标记的词典中（同一个NSURLSession中的taskIdentifier是唯一的）
    self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)] = delegate;
    // 设置uploadProgress和downloadProgress这两个NSProgress变量
    [delegate setupProgressForTask:task];
    //给session task添加监听(KVO)
    [self addNotificationObserverForTask:task];
    //解锁
    [self.lock unlock];
}

- (void)addDelegateForDataTask:(NSURLSessionDataTask *)dataTask
                uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
              downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
             completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    /*
     创建一个AFURLSessionManagerTaskDelegate代理类的对象，并为几个属性赋值。然后调用setDelegate:forTask:将其和dataTask绑定
     
     AFNet通过封装AFURLSessionManagerTaskDelegate对象，对每个task 进行管理，而AFURLSessionManager仅需要管理建立task 与AF delegate的词典即可，实现了AFURLSessionManager功能的下放。

     */
    
    //实例化AFURLSessionManagerTaskDelegate对象
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
    // AFURLSessionManagerTaskDelegate与AFURLSessionManager建立相互关系
    delegate.manager = self;
    //设置AFURLSessionManagerTaskDelegate delegate的完成块为用户传入的完成块 task完成后的回调
    delegate.completionHandler = completionHandler;
    //指定Task与taskDescriptionForSessionTasks的关联关系，方便后面的通知中做对应的处理。
    dataTask.taskDescription = self.taskDescriptionForSessionTasks;
    //讲delegate与dataTask建立联系 添加通知
    [self setDelegate:delegate forTask:dataTask];

    //设置delegate上传进度 和 下载进度块
    delegate.uploadProgressBlock = uploadProgressBlock;
    delegate.downloadProgressBlock = downloadProgressBlock;
}

- (void)addDelegateForUploadTask:(NSURLSessionUploadTask *)uploadTask
                        progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
               completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;

    uploadTask.taskDescription = self.taskDescriptionForSessionTasks;

    [self setDelegate:delegate forTask:uploadTask];

    delegate.uploadProgressBlock = uploadProgressBlock;
}

- (void)addDelegateForDownloadTask:(NSURLSessionDownloadTask *)downloadTask
                          progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                       destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                 completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
    delegate.manager = self;
    //task完成后的回调
    delegate.completionHandler = completionHandler;

    if (destination) {
        delegate.downloadTaskDidFinishDownloading = ^NSURL * (NSURLSession * __unused session, NSURLSessionDownloadTask *task, NSURL *location) {
            return destination(location, task.response);
        };
    }

    //指定Task与taskDescriptionForSessionTasks的关联关系，方便后面的通知中做对应的处理。
    downloadTask.taskDescription = self.taskDescriptionForSessionTasks;
    //添加通知
    [self setDelegate:delegate forTask:downloadTask];
    //设置一个下载进度的Block，以便在后面代理方法中调用。
    delegate.downloadProgressBlock = downloadProgressBlock;
}

- (void)removeDelegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    [self.lock lock];
    //清除监听
    [delegate cleanUpProgressForTask:task];
    //移除Task对应的通知
    [self removeNotificationObserverForTask:task];
    //移除Task对应的`AFURLSessionManagerTaskDelegate`代理对象。
    [self.mutableTaskDelegatesKeyedByTaskIdentifier removeObjectForKey:@(task.taskIdentifier)];
    [self.lock unlock];
}

#pragma mark - 获取当前session对应的task列表 通过dispatch_semaphore_t来控制访问过程
- (NSArray *)tasksForKeyPath:(NSString *)keyPath {
    __block NSArray *tasks = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(dataTasks))]) {
            tasks = dataTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(uploadTasks))]) {
            tasks = uploadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(downloadTasks))]) {
            tasks = downloadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(tasks))]) {
            tasks = [@[dataTasks, uploadTasks, downloadTasks] valueForKeyPath:@"@unionOfArrays.self"];
        }
        //发送一个信号量 让semapore 变为1
        dispatch_semaphore_signal(semaphore);
    }];
    //这里会一直等到信号量变为1
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    //返回task 通过信号量控制 便面啦方法结束的时候 task还没有正常获取的情况
    return tasks;
}

- (NSArray *)tasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)dataTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)uploadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)downloadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

#pragma mark -

- (void)invalidateSessionCancelingTasks:(BOOL)cancelPendingTasks {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cancelPendingTasks) {
            [self.session invalidateAndCancel];
        } else {
            [self.session finishTasksAndInvalidate];
        }
    });
}

#pragma mark -

- (void)setResponseSerializer:(id <AFURLResponseSerialization>)responseSerializer {
    NSParameterAssert(responseSerializer);

    _responseSerializer = responseSerializer;
}

#pragma mark -
- (void)addNotificationObserverForTask:(NSURLSessionTask *)task {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidResume:) name:AFNSURLSessionTaskDidResumeNotification object:task];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidSuspend:) name:AFNSURLSessionTaskDidSuspendNotification object:task];
}

- (void)removeNotificationObserverForTask:(NSURLSessionTask *)task {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidSuspendNotification object:task];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidResumeNotification object:task];
}

#pragma mark -

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    return [self dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                               uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                             downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                            completionHandler:(nullable void (^)(NSURLResponse *response, id _Nullable responseObject,  NSError * _Nullable error))completionHandler {

    __block NSURLSessionDataTask *dataTask = nil;
    //解决iOS8bug
    url_session_manager_create_task_safely(^{
        //用NSURLSession创建NSURLSessionDataTask对象
        dataTask = [self.session dataTaskWithRequest:request];
    });

    //为该dataTask设置delegate(AFURLSessionManagerTaskDelegate)，一一绑定
    //主要是为task提供上传下载的进度管理功能
    [self addDelegateForDataTask:dataTask uploadProgress:uploadProgressBlock downloadProgress:downloadProgressBlock completionHandler:completionHandler];

    return dataTask;
}

#pragma mark -

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromFile:(NSURL *)fileURL
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    __block NSURLSessionUploadTask *uploadTask = nil;
    //用线程安全的方式创建一个dataTask。修复iOS8下面的bug。
    url_session_manager_create_task_safely(^{
        uploadTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
    });
    //用于处理uploadTask在iOS7环境下面有可能创建失败的情况，如果attemptsToRecreateUploadTasksForBackgroundSessions为true 则尝试重新创建task 如果三次都没有成功 则放弃
    if (!uploadTask && self.attemptsToRecreateUploadTasksForBackgroundSessions && self.session.configuration.identifier) {
        for (NSUInteger attempts = 0; !uploadTask && attempts < AFMaximumNumberOfAttemptsToRecreateBackgroundSessionUploadTask; attempts++) {
            uploadTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
        }
    }

    //为task添加AFURLSessionManagerTaskDelegate代理方法
    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    __block NSURLSessionUploadTask *uploadTask = nil;
    url_session_manager_create_task_safely(^{
        uploadTask = [self.session uploadTaskWithRequest:request fromData:bodyData];
    });

    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request
                                                 progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                        completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    __block NSURLSessionUploadTask *uploadTask = nil;
    url_session_manager_create_task_safely(^{
        uploadTask = [self.session uploadTaskWithStreamedRequest:request];
    });

    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

#pragma mark -

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                             progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                          destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                    completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    __block NSURLSessionDownloadTask *downloadTask = nil;
    url_session_manager_create_task_safely(^{
        downloadTask = [self.session downloadTaskWithRequest:request];
    });

    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData
                                                progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                             destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                       completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    __block NSURLSessionDownloadTask *downloadTask = nil;
    url_session_manager_create_task_safely(^{
        downloadTask = [self.session downloadTaskWithResumeData:resumeData];
    });

    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

#pragma mark -
- (NSProgress *)uploadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] uploadProgress];
}

- (NSProgress *)downloadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] downloadProgress];
}

#pragma mark -

- (void)setSessionDidBecomeInvalidBlock:(void (^)(NSURLSession *session, NSError *error))block {
    self.sessionDidBecomeInvalid = block;
}

- (void)setSessionDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.sessionDidReceiveAuthenticationChallenge = block;
}

- (void)setDidFinishEventsForBackgroundURLSessionBlock:(void (^)(NSURLSession *session))block {
    self.didFinishEventsForBackgroundURLSession = block;
}

#pragma mark -

- (void)setTaskNeedNewBodyStreamBlock:(NSInputStream * (^)(NSURLSession *session, NSURLSessionTask *task))block {
    self.taskNeedNewBodyStream = block;
}

- (void)setTaskWillPerformHTTPRedirectionBlock:(NSURLRequest * (^)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request))block {
    self.taskWillPerformHTTPRedirection = block;
}

- (void)setTaskDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.taskDidReceiveAuthenticationChallenge = block;
}

- (void)setTaskDidSendBodyDataBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend))block {
    self.taskDidSendBodyData = block;
}

- (void)setTaskDidCompleteBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, NSError *error))block {
    self.taskDidComplete = block;
}

#pragma mark -

- (void)setDataTaskDidReceiveResponseBlock:(NSURLSessionResponseDisposition (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response))block {
    self.dataTaskDidReceiveResponse = block;
}

- (void)setDataTaskDidBecomeDownloadTaskBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask))block {
    self.dataTaskDidBecomeDownloadTask = block;
}

- (void)setDataTaskDidReceiveDataBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data))block {
    self.dataTaskDidReceiveData = block;
}

- (void)setDataTaskWillCacheResponseBlock:(NSCachedURLResponse * (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse))block {
    self.dataTaskWillCacheResponse = block;
}

#pragma mark -

- (void)setDownloadTaskDidFinishDownloadingBlock:(NSURL * (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location))block {
    self.downloadTaskDidFinishDownloading = block;
}

- (void)setDownloadTaskDidWriteDataBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite))block {
    self.downloadTaskDidWriteData = block;
}

- (void)setDownloadTaskDidResumeBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes))block {
    self.downloadTaskDidResume = block;
}

#pragma mark - NSObject

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, session: %@, operationQueue: %@>", NSStringFromClass([self class]), self, self.session, self.operationQueue];
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)) {
        return self.taskWillPerformHTTPRedirection != nil;
    } else if (selector == @selector(URLSession:dataTask:didReceiveResponse:completionHandler:)) {
        return self.dataTaskDidReceiveResponse != nil;
    } else if (selector == @selector(URLSession:dataTask:willCacheResponse:completionHandler:)) {
        return self.dataTaskWillCacheResponse != nil;
    } else if (selector == @selector(URLSessionDidFinishEventsForBackgroundURLSession:)) {
        return self.didFinishEventsForBackgroundURLSession != nil;
    }

    return [[self class] instancesRespondToSelector:selector];
}

#pragma mark - NSURLSessionDelegate
#pragma mark - 当一个sessio遇到系统错误或者未检测到的错误的时候 会调用
- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(NSError *)error
{
    if (self.sessionDidBecomeInvalid) {
        self.sessionDidBecomeInvalid(session, error);
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDidInvalidateNotification object:session];
}
#pragma mark - 当请求需要认证、或者https证书认证的时候、需要再这个方法里面处理
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    if (self.sessionDidReceiveAuthenticationChallenge) {
        disposition = self.sessionDidReceiveAuthenticationChallenge(session, challenge, &credential);
    } else {
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                if (credential) {
                    disposition = NSURLSessionAuthChallengeUseCredential;
                } else {
                    disposition = NSURLSessionAuthChallengePerformDefaultHandling;
                }
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

#pragma mark - NSURLSessionTaskDelegate


/**
 当请求返回302状态的时候，表示这个请求需要重定向到另一个url，可以做哎这个代理中决定对于重定向的处理
 也就是说调用这个方法的时候必须设置一个新的‘NSURLRequest’对象传入completionHandler来重定向新的请求 但是当session时background模式的时候 不会调用这个方法
 @param session session
 @param task task
 @param response response
 @param request request
 @param completionHandler 请求完成
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    //重定向的request对象
    NSURLRequest *redirectRequest = request;
    //如果用户指定啦taskWillPerformHTTPRedirection这个block ，那么久调用他返回处理完成的request对象
    if (self.taskWillPerformHTTPRedirection) {
        redirectRequest = self.taskWillPerformHTTPRedirection(session, task, response, request);
    }

    //执行重定向操作
    if (completionHandler) {
        completionHandler(redirectRequest);
    }
}

/*
 当请求需要认证的时候调用这个方法，如果没有实现这个代理，那么请求认证这个过程不会被调用
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    if (self.taskDidReceiveAuthenticationChallenge) {
        disposition = self.taskDidReceiveAuthenticationChallenge(session, task, challenge, &credential);
    } else {
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                disposition = NSURLSessionAuthChallengeUseCredential;
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

/*
 如果请求需要一个新的请求体时，这个方法就会被调用。如果认证失败的时候，我们可以通过这个机会重新认证
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler
{
    NSInputStream *inputStream = nil;

    if (self.taskNeedNewBodyStream) {
        inputStream = self.taskNeedNewBodyStream(session, task);
    } else if (task.originalRequest.HTTPBodyStream && [task.originalRequest.HTTPBodyStream conformsToProtocol:@protocol(NSCopying)]) {
        inputStream = [task.originalRequest.HTTPBodyStream copy];
    }

    if (completionHandler) {
        completionHandler(inputStream);
    }
}

/*
 上传数据的时候 可以通过这个代理方法获取上传进度
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{

    int64_t totalUnitCount = totalBytesExpectedToSend;
    if(totalUnitCount == NSURLSessionTransferSizeUnknown) {
        NSString *contentLength = [task.originalRequest valueForHTTPHeaderField:@"Content-Length"];
        if(contentLength) {
            totalUnitCount = (int64_t) [contentLength longLongValue];
        }
    }

    if (self.taskDidSendBodyData) {
        self.taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalUnitCount);
    }
}

/*
 当一个Task数据返回完全以后，会调用这个方法
 当一个task出错的时候 调用该方法 如果error是nil 也会调用 表示task完成
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    //获取Task对应的`AFURLSessionManagerTaskDelegate`从而让他的代理方法执行。
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];

    // delegate may be nil when completing a task in the background
    //当时background模式的Task，delegate有可能是nil。
    if (delegate) {
        [delegate URLSession:session task:task didCompleteWithError:error];

        [self removeDelegateForTask:task];
    }

    if (self.taskDidComplete) {
        self.taskDidComplete(session, task, error);
    }
}

#pragma mark - NSURLSessionDataDelegate

/*
 当一个task收到返回的信息。当所有的信息都接完毕以后，completionHandler会被调用，
 */
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;

    if (self.dataTaskDidReceiveResponse) {
        disposition = self.dataTaskDidReceiveResponse(session, dataTask, response);
    }

    if (completionHandler) {
        completionHandler(disposition);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    if (delegate) {
        [self removeDelegateForTask:dataTask];
        [self setDelegate:delegate forTask:downloadTask];
    }

    if (self.dataTaskDidBecomeDownloadTask) {
        self.dataTaskDidBecomeDownloadTask(session, dataTask, downloadTask);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{

    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    [delegate URLSession:session dataTask:dataTask didReceiveData:data];

    if (self.dataTaskDidReceiveData) {
        self.dataTaskDidReceiveData(session, dataTask, data);
    }
}

//调用completionHandler缓存data 或者传入nil禁止缓存
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.dataTaskWillCacheResponse) {
        cachedResponse = self.dataTaskWillCacheResponse(session, dataTask, proposedResponse);
    }

    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

#pragma mark - 如果应用进入后台 这个方法会被调用 我们在这里可以对session发起的请求做各种操作 比如请求完成的回调
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (self.didFinishEventsForBackgroundURLSession) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.didFinishEventsForBackgroundURLSession(session);
        });
    }
}

#pragma mark - NSURLSessionDownloadDelegate

//当一个下载task任务完成以后，这个方法会被调用
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    if (self.downloadTaskDidFinishDownloading) {
        NSURL *fileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (fileURL) {
            delegate.downloadFileURL = fileURL;
            NSError *error = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&error];
            if (error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:error.userInfo];
            }

            return;
        }
    }

    if (delegate) {
        [delegate URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
    }
}

/**
 在网络请求正式开始以后，这个方法会在数据接收的过程中多次调用。我们可以通过这个方法获取数据下载的大小、总得大小、还有多少么有下载
 
 @param session session
 @param downloadTask 对应的Task
 @param bytesWritten 已经下载的字节
 @param totalBytesWritten 总的字节大小
 @param totalBytesExpectedToWrite nil
 */
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (self.downloadTaskDidWriteData) {
        //如果有`downloadTaskDidWriteData`Block的实现，则在这个调用Block从而实现对下载进度过程的控制。
        self.downloadTaskDidWriteData(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    }
}

/*
 重启一个下载任务(比如下载一半后停止然后过一点时间继续)。如果下载出错，`NSURLSessionDownloadTaskResumeData`里面包含重新开始下载的数据。
 */
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    if (self.downloadTaskDidResume) {
        self.downloadTaskDidResume(session, downloadTask, fileOffset, expectedTotalBytes);
    }
}

#pragma mark - NSSecureCoding

// 在iOS8以及以上环境下，supportsSecureCoding必须重写并且返回true。
+ (BOOL)supportsSecureCoding {
    return YES;
}
//解档
- (instancetype)initWithCoder:(NSCoder *)decoder {
    NSURLSessionConfiguration *configuration = [decoder decodeObjectOfClass:[NSURLSessionConfiguration class] forKey:@"sessionConfiguration"];

    self = [self initWithSessionConfiguration:configuration];
    if (!self) {
        return nil;
    }

    return self;
}
/**
 我们发现对象归档的时候，只归档了`NSURLSessionConfiguration`属性。所以说归档接档的时候所有Block设置、operation设置都会失效。
 */
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.session.configuration forKey:@"sessionConfiguration"];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithSessionConfiguration:self.session.configuration];
}

@end
