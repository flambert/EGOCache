//
//  EGOCache.m
//  enormego
//
//  Created by Shaun Harrison on 7/4/09.
//  Copyright (c) 2009-2010 enormego
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "EGOCache.h"

#if DEBUG
	#define CHECK_FOR_EGOCACHE_PLIST() if([key isEqualToString:@"EGOCache.plist"]) { \
		NSLog(@"EGOCache.plist is a reserved key and can not be modified."); \
		return; }
#else
	#define CHECK_FOR_EGOCACHE_PLIST() if([key isEqualToString:@"EGOCache.plist"]) return;
#endif

static NSString* _EGOCacheDirectory;

static inline NSString* EGOCacheDirectory() {
	if(!_EGOCacheDirectory) {
		NSString* cachesDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
		_EGOCacheDirectory = [[[cachesDirectory stringByAppendingPathComponent:[[NSProcessInfo processInfo] processName]] stringByAppendingPathComponent:@"EGOCache"] copy];
	}
	
	return _EGOCacheDirectory;
}

static inline NSString* cachePathForKey(NSString* key) {
	return [EGOCacheDirectory() stringByAppendingPathComponent:key];
}

static EGOCache* __instance;

@interface EGOCache ()
- (void)removeItemFromCache:(NSString*)key;
- (void)performDiskWriteOperation:(NSInvocation *)invocation;
- (void)saveAfterDelay;
- (id)itemForKey:(NSString*)key readFromDiskWithSelector:(SEL)selector;
@end

#pragma mark -

@implementation EGOCache
@synthesize defaultTimeoutInterval;
@synthesize useMemoryCache;

+ (EGOCache*)currentCache {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __instance = [[EGOCache alloc] init];
        __instance.defaultTimeoutInterval = 86400;
        __instance.useMemoryCache = YES;
    });
	
	return __instance;
}

+ (NSString*)keyForPrefix:(NSString*)prefix url:(NSURL*)url {
    return [EGOCache keyForPrefix:prefix string:[url absoluteString]];
}

+ (NSString*)keyForPrefix:(NSString*)prefix string:(NSString*)string {
    NSRange schemeRange = [string rangeOfString:@"://"];
    if (schemeRange.location == NSNotFound || schemeRange.length == 0)
        schemeRange = NSMakeRange(0, 0);
    
    return [NSString stringWithFormat:@"%@/%@", prefix, [[string substringFromIndex:NSMaxRange(schemeRange)] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
}

- (id)init {
	if((self = [super init])) {
        // Load cache dictionary
		NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:cachePathForKey(@"EGOCache.plist")];
		
		if([dict isKindOfClass:[NSDictionary class]]) {
			cacheDictionary = [dict mutableCopy];
		} else {
			cacheDictionary = [[NSMutableDictionary alloc] init];
		}
		
        // Init operation queue
		diskOperationQueue = [[NSOperationQueue alloc] init];
		
        // Init memory cache
        memoryCache = [[NSMutableDictionary alloc] init];
        
        // Handle memory warnings
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        
        // Create the cache directory
		[[NSFileManager defaultManager] createDirectoryAtPath:EGOCacheDirectory() 
								  withIntermediateDirectories:YES 
												   attributes:nil 
														error:NULL];
		
        // Remove expired items from cache
		for(NSString* key in cacheDictionary) {
			NSDate* date = [cacheDictionary objectForKey:key];
			if([[[NSDate date] earlierDate:date] isEqualToDate:date]) {
				[[NSFileManager defaultManager] removeItemAtPath:cachePathForKey(key) error:NULL];
			}
		}
	}
	
	return self;
}

- (void)clearCache {
    @synchronized(self) {
        for(NSString* key in [cacheDictionary allKeys]) {
            [self removeItemFromCache:key];
        }

        [memoryCache removeAllObjects];
    }
    
    [self performSelectorOnMainThread:@selector(saveAfterDelay) withObject:nil waitUntilDone:YES]; // Need to make sure the save delay get scheduled in the main runloop, not the current threads
}

- (void)clearMemoryCache {
    @synchronized(self) {
        [memoryCache removeAllObjects];
    }
}

- (void)removeCacheForKey:(NSString*)key {
	CHECK_FOR_EGOCACHE_PLIST();
    
    @synchronized(self) {
        [self removeItemFromCache:key];
    }
    
    [self performSelectorOnMainThread:@selector(saveAfterDelay) withObject:nil waitUntilDone:YES]; // Need to make sure the save delay get scheduled in the main runloop, not the current threads
}

- (void)removeItemFromCache:(NSString*)key {
    NSString* cachePath = cachePathForKey(key);
    
    NSInvocation* deleteInvocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(deleteDataAtPath:)]];
    [deleteInvocation setTarget:self];
    [deleteInvocation setSelector:@selector(deleteDataAtPath:)];
    [deleteInvocation setArgument:&cachePath atIndex:2];
    
    [self performDiskWriteOperation:deleteInvocation];
    [cacheDictionary removeObjectForKey:key];
    [memoryCache removeObjectForKey:key];
}

- (BOOL)nonAtomicHasCacheForKey:(NSString*)key {
    NSDate* date = [cacheDictionary objectForKey:key];
    if(!date) return NO;
    if([[[NSDate date] earlierDate:date] isEqualToDate:date]) return NO;
    if([memoryCache objectForKey:key]) return YES;
    return [[NSFileManager defaultManager] fileExistsAtPath:cachePathForKey(key)];
}

- (BOOL)hasCacheForKey:(NSString*)key {
    @synchronized(self) {
        return [self nonAtomicHasCacheForKey:key];
    }
}

- (void)handleMemoryWarning:(NSNotification *)notification {
    if ([notification.name isEqualToString:UIApplicationDidReceiveMemoryWarningNotification]) {
        [self clearMemoryCache];
    }
}

- (id)itemForKey:(NSString *)key readFromDiskWithSelector:(SEL)selector {
    @synchronized(self) {
        id item = nil;
        if([self nonAtomicHasCacheForKey:key]) {
            if (useMemoryCache) {
                if((item = [memoryCache objectForKey:key]) == nil) {
                    if((item = [self performSelector:selector withObject:key]) != nil) {
                        [memoryCache setObject:item forKey:key];
                    }
                }
            } else {
                item = [self performSelector:selector withObject:key];
            }
        }
        
        return item;
    }
}

#pragma mark -
#pragma mark Copy file methods

- (void)copyFilePath:(NSString*)filePath asKey:(NSString*)key {
	[self copyFilePath:filePath asKey:key withTimeoutInterval:self.defaultTimeoutInterval];
}

- (void)copyFilePath:(NSString*)filePath asKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
    @synchronized(self) {
        [[NSFileManager defaultManager] copyItemAtPath:filePath toPath:cachePathForKey(key) error:NULL];
        [cacheDictionary setObject:[NSDate dateWithTimeIntervalSinceNow:timeoutInterval] forKey:key];
    }
    
    [self performSelectorOnMainThread:@selector(saveAfterDelay) withObject:nil waitUntilDone:YES]; // Need to make sure the save delay get scheduled in the main runloop, not the current threads
}

#pragma mark -
#pragma mark Data methods

- (id)readDataFromDiskForKey:(NSString*)key {
    return [NSData dataWithContentsOfFile:cachePathForKey(key) options:0 error:NULL];
}

- (NSData*)dataForKey:(NSString*)key {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readDataFromDiskForKey:)];
}

- (void)setData:(NSData*)data forKey:(NSString*)key {
    [self setData:data forKey:key withTimeoutInterval:self.defaultTimeoutInterval memoryCachedObject:nil];
}

- (void)setData:(NSData*)data forKey:(NSString*)key memoryCachedObject:(id)object {
    [self setData:data forKey:key withTimeoutInterval:self.defaultTimeoutInterval memoryCachedObject:object];
}

- (void)setData:(NSData*)data forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
    [self setData:data forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:nil];
}

- (void)setData:(NSData*)data forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval memoryCachedObject:(id)object {
	CHECK_FOR_EGOCACHE_PLIST();
	
    @synchronized(self) {
        NSString* cachePath = cachePathForKey(key);
        NSInvocation* writeInvocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(writeData:toPath:)]];
        [writeInvocation setTarget:self];
        [writeInvocation setSelector:@selector(writeData:toPath:)];
        [writeInvocation setArgument:&data atIndex:2];
        [writeInvocation setArgument:&cachePath atIndex:3];
        
        [self performDiskWriteOperation:writeInvocation];
        [cacheDictionary setObject:[NSDate dateWithTimeIntervalSinceNow:timeoutInterval] forKey:key];
        
        if (useMemoryCache && object) {
            [memoryCache setObject:object forKey:key];
        }
    }
    
    [self performSelectorOnMainThread:@selector(saveAfterDelay) withObject:nil waitUntilDone:YES]; // Need to make sure the save delay get scheduled in the main runloop, not the current threads
}

- (void)saveCacheDictionary {
	@synchronized(self) {
		[cacheDictionary writeToFile:cachePathForKey(@"EGOCache.plist") atomically:YES];
	}
}

- (void)saveAfterDelay { // Prevents multiple-rapid saves from happening, which will slow down your app
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveCacheDictionary) object:nil];
	[self performSelector:@selector(saveCacheDictionary) withObject:nil afterDelay:0.3];
}

- (void)writeData:(NSData*)data toPath:(NSString *)path; {
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:NULL];
    [data writeToFile:path atomically:YES];
} 

- (void)deleteDataAtPath:(NSString *)path {
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

#pragma mark -
#pragma mark String methods

- (id)readStringFromDiskForKey:(NSString*)key {
    return [[[NSString alloc] initWithData:[self dataForKey:key] encoding:NSUTF8StringEncoding] autorelease];
}

- (NSString*)stringForKey:(NSString*)key {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readStringFromDiskForKey:)];
}

- (void)setString:(NSString*)aString forKey:(NSString*)key {
	[self setString:aString forKey:key withTimeoutInterval:self.defaultTimeoutInterval];
}

- (void)setString:(NSString*)aString forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
	[self setData:[aString dataUsingEncoding:NSUTF8StringEncoding] forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:aString];
}

#pragma mark -
#pragma mark Image methds

#if TARGET_OS_IPHONE

- (id)readImageFromDiskForKey:(NSString*)key {
    return [UIImage imageWithContentsOfFile:cachePathForKey(key)];
}

- (UIImage*)imageForKey:(NSString*)key {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readImageFromDiskForKey:)];
}

- (void)setImage:(UIImage*)anImage forKey:(NSString*)key {
	[self setImage:anImage forKey:key withTimeoutInterval:self.defaultTimeoutInterval];
}

- (void)setImage:(UIImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
	[self setData:UIImagePNGRepresentation(anImage) forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:anImage];
}

#else

- (id)readImageFromDiskForKey:(NSString*)key {
    return [[[NSImage alloc] initWithData:[self dataForKey:key]] autorelease];
}

- (NSImage*)imageForKey:(NSString*)key {
    return [self itemFromKey:key readFromDiskWithSelector:@selector(readImageFromDiskForKey:)];
}

- (void)setImage:(NSImage*)anImage forKey:(NSString*)key {
	[self setImage:anImage forKey:key withTimeoutInterval:self.defaultTimeoutInterval];
}

- (void)setImage:(NSImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
	[self setData:[[[anImage representations] objectAtIndex:0] representationUsingType:NSPNGFileType properties:nil]
           forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:anImage];
}

#endif

#pragma mark -
#pragma mark Property List methods

- (id)readPlistFromDiskForKey:(NSString*)key {
    return [NSPropertyListSerialization propertyListFromData:[self dataForKey:key] mutabilityOption:NSPropertyListImmutable format:nil errorDescription:nil];
}

- (NSData*)plistForKey:(NSString*)key; {  
    return [self itemForKey:key readFromDiskWithSelector:@selector(readPlistFromDiskForKey:)];
}

- (void)setPlist:(id)plistObject forKey:(NSString*)key; {
	[self setPlist:plistObject forKey:key withTimeoutInterval:self.defaultTimeoutInterval];
}

- (void)setPlist:(id)plistObject forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval; {
	// Binary plists are used over XML for better performance
	NSData* plistData = [NSPropertyListSerialization dataFromPropertyList:plistObject 
																   format:NSPropertyListBinaryFormat_v1_0
														 errorDescription:NULL];
	
	[self setData:plistData forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:plistObject];
}

#pragma mark -
#pragma mark Objects methods

- (id)readObjectFromDiskForKey:(NSString*)key {
    return [NSKeyedUnarchiver unarchiveObjectWithData:[self dataForKey:key]];
}

- (id)objectForKey:(NSString*)key {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readObjectFromDiskForKey:)];
}

- (void)setObject:(id)object forKey:(NSString*)key {
	[self setObject:object forKey:key withTimeoutInterval:self.defaultTimeoutInterval];
}   

- (void)setObject:(id)object forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
    [self setData:[NSKeyedArchiver archivedDataWithRootObject:object] forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:object];
}


#pragma mark -
#pragma mark Disk writing operations

- (void)performDiskWriteOperation:(NSInvocation *)invocation {
	NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithInvocation:invocation];
	[diskOperationQueue addOperation:operation];
	[operation release];
}

#pragma mark -

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [memoryCache release];
	[diskOperationQueue release];
	[cacheDictionary release];
	[super dealloc];
}

@end