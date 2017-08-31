# CodeStudy
主要对以下第三方源码阅读 以及版本号
 AFNetworking (3.1.0)
 SDWebImage (4.1.0)
 YYModel (1.0.4)
 YYCache (1.0.4)
 FMDB (2.7.2)


# AFNetworking 
1：AFHTTPSessionManager 调用
- (NSURLSessionDataTask *)GET:(NSString *)URLString 
                            parameters:(id)parameters
                            progress:(void (^)(NSProgress * _Nonnull))downloadProgress
                            success:(void (^)(NSURLSessionDataTask * _Nonnull, id _Nullable))success
                            failure:(void (^)(NSURLSessionDataTask * _Nullable, NSError * _Nonnull))failure
创建dataTask实例
