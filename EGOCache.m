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
- (id)itemForKey:(NSString*)key readFromDiskWithSelector:(SEL)selector useMemoryCache:(BOOL)useMemoryCache;
@end

#pragma mark -

@implementation EGOCache
@synthesize defaultTimeoutInterval;
@synthesize defaultUseMemoryCache;

+ (EGOCache*)currentCache {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __instance = [[EGOCache alloc] init];
        __instance.defaultTimeoutInterval = 86400;
        __instance.defaultUseMemoryCache = YES;
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
#if EGO_CACHE_USE_NS_CACHE
        memoryCache = [[NSCache alloc] init];
        memoryCache.name = @"EGOCache";
#else
        memoryCache = [[NSMutableDictionary alloc] init];
        
        // Handle memory warnings
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
        
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
        //NSLog(@"clearMemoryCache: %@", memoryCache);
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

- (BOOL)nonAtomicHasCacheForKey:(NSString*)key checkOnlyMemory:(BOOL)checkOnlyMemory{
    NSDate* date = [cacheDictionary objectForKey:key];
    if(!date) return NO;
    if([[[NSDate date] earlierDate:date] isEqualToDate:date]) return NO;
    if([memoryCache objectForKey:key]) return YES;
    if (!checkOnlyMemory) {
        return [[NSFileManager defaultManager] fileExistsAtPath:cachePathForKey(key)];
    } else {
        return NO;
    }
}

- (BOOL)nonAtomicHasCacheForKey:(NSString*)key {
    return [self nonAtomicHasCacheForKey:key checkOnlyMemory:NO];
}

- (BOOL)hasCacheForKey:(NSString*)key {
    return [self hasCacheForKey:key checkOnlyMemory:NO];
}

- (BOOL)hasCacheForKey:(NSString*)key checkOnlyMemory:(BOOL)checkOnlyMemory {
    @synchronized(self) {
        return [self nonAtomicHasCacheForKey:key checkOnlyMemory:checkOnlyMemory];
    }
}

#if EGO_CACHE_USE_NS_CACHE
#else
- (void)handleMemoryWarning:(NSNotification *)notification {
    if ([notification.name isEqualToString:UIApplicationDidReceiveMemoryWarningNotification]) {
        [self clearMemoryCache];
    }
}
#endif

- (id)itemForKey:(NSString *)key readFromDiskWithSelector:(SEL)selector useMemoryCache:(BOOL)useMemoryCache {
    @synchronized(self) {
        id item = nil;
        if([self nonAtomicHasCacheForKey:key]) {
            if (useMemoryCache) {
                if((item = [memoryCache objectForKey:key]) == nil) {
                    if((item = [self performSelector:selector withObject:key withObject:[NSNumber numberWithBool:useMemoryCache]]) != nil) {
                        [memoryCache setObject:item forKey:key];
                    }
                }
            } else {
                item = [self performSelector:selector withObject:key withObject:[NSNumber numberWithBool:useMemoryCache]];
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

- (id)readDataFromDiskForKey:(NSString*)key useMemoryCache:(NSNumber*)useMemoryCache {
    return [NSData dataWithContentsOfFile:cachePathForKey(key) options:0 error:NULL];
}

- (NSData*)dataForKey:(NSString*)key {
    return [self dataForKey:key useMemoryCache:self.defaultUseMemoryCache];
}

- (NSData*)dataForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readDataFromDiskForKey:useMemoryCache:) useMemoryCache:useMemoryCache];
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

- (void)setData:(NSData*)data forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval memoryCachedObject:(id)memoryCachedObject {
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
        
        if (memoryCachedObject) {
            [memoryCache setObject:memoryCachedObject forKey:key];
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

- (void)writeData:(NSData*)data toPath:(NSString *)path {
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

- (id)readStringFromDiskForKey:(NSString*)key useMemoryCache:(NSNumber*)useMemoryCache {
    return [[[NSString alloc] initWithData:[self dataForKey:key] encoding:NSUTF8StringEncoding] autorelease];
}

- (NSString*)stringForKey:(NSString*)key {
    return [self stringForKey:key useMemoryCache:self.defaultUseMemoryCache];
}

- (NSString*)stringForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readStringFromDiskForKey:useMemoryCache:) useMemoryCache:useMemoryCache];
}

- (void)setString:(NSString*)aString forKey:(NSString*)key {
	[self setString:aString forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setString:(NSString*)aString forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
	[self setString:aString forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:useMemoryCache];
}

- (void)setString:(NSString*)aString forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
    [self setString:aString forKey:key withTimeoutInterval:timeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setString:(NSString*)aString forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache {
	[self setData:[aString dataUsingEncoding:NSUTF8StringEncoding] forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:(useMemoryCache ? aString : nil)];
}

#pragma mark -
#pragma mark Image methds

#if TARGET_OS_IPHONE

- (id)readImageFromDiskForKey:(NSString*)key useMemoryCache:(NSNumber*)useMemoryCache {
    return [UIImage imageWithContentsOfFile:cachePathForKey(key)];
}

- (UIImage*)imageForKey:(NSString*)key {
    return [self imageForKey:key useMemoryCache:self.defaultUseMemoryCache];
}

- (UIImage*)imageForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readImageFromDiskForKey:useMemoryCache:) useMemoryCache:useMemoryCache];
}

- (void)setImage:(UIImage*)anImage forKey:(NSString*)key {
	[self setImage:anImage forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setImage:(UIImage*)anImage forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
	[self setImage:anImage forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:useMemoryCache];
}

- (void)setImage:(UIImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
	[self setImage:anImage forKey:key withTimeoutInterval:timeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setImage:(UIImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache {
	[self setData:UIImagePNGRepresentation(anImage) forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:(useMemoryCache ? anImage : nil)];
}

#else

- (id)readImageFromDiskForKey:(NSString*)key useMemoryCache:(NSNumber*)useMemoryCache {
    return [[[NSImage alloc] initWithData:[self dataForKey:key]] autorelease];
}

- (NSImage*)imageForKey:(NSString*)key {
    return [self imageForKey:key useMemoryCache:self.defaultUseMemoryCache];
}

- (NSImage*)imageForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
    return [self itemFromKey:key readFromDiskWithSelector:@selector(readImageFromDiskForKey:useMemoryCache) useMemoryCache:useMemoryCache];
}

- (void)setImage:(NSImage*)anImage forKey:(NSString*)key {
	[self setImage:anImage forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setImage:(NSImage*)anImage forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
	[self setImage:anImage forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:useMemoryCache];
}

- (void)setImage:(NSImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
	[self setImage:anImage forKey:key withTimeoutInterval:timeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setImage:(NSImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache {
	[self setData:[[[anImage representations] objectAtIndex:0] representationUsingType:NSPNGFileType properties:nil]
           forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:(useMemoryCache ? anImage: nil)];
}

#endif

#pragma mark -
#pragma mark Property List methods

- (id)readPlistFromDiskForKey:(NSString*)key useMemoryCache:(NSNumber*)useMemoryCache {
    return [NSPropertyListSerialization propertyListFromData:[self dataForKey:key] mutabilityOption:NSPropertyListImmutable format:nil errorDescription:nil];
}

- (NSData*)plistForKey:(NSString*)key {
    return [self plistForKey:key useMemoryCache:self.defaultUseMemoryCache];
}

- (NSData*)plistForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readPlistFromDiskForKey:useMemoryCache:) useMemoryCache:useMemoryCache];
}

- (void)setPlist:(id)plistObject forKey:(NSString*)key {
	[self setPlist:plistObject forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setPlist:(id)plistObject forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
	[self setPlist:plistObject forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:useMemoryCache];
}

- (void)setPlist:(id)plistObject forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
	[self setPlist:plistObject forKey:key withTimeoutInterval:timeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setPlist:(id)plistObject forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache {
	// Binary plists are used over XML for better performance
	NSData* plistData = [NSPropertyListSerialization dataFromPropertyList:plistObject 
																   format:NSPropertyListBinaryFormat_v1_0
														 errorDescription:NULL];
	
	[self setData:plistData forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:(useMemoryCache ? plistObject : nil)];
}

#pragma mark -
#pragma mark Objects methods

- (id)readObjectFromDiskForKey:(NSString*)key useMemoryCache:(NSNumber*)useMemoryCache {
    return [NSKeyedUnarchiver unarchiveObjectWithData:[self dataForKey:key useMemoryCache:[useMemoryCache boolValue]]];
}

- (id)objectForKey:(NSString*)key {
    return [self objectForKey:key useMemoryCache:self.defaultUseMemoryCache];
}

- (id)objectForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
    return [self itemForKey:key readFromDiskWithSelector:@selector(readObjectFromDiskForKey:useMemoryCache:) useMemoryCache:useMemoryCache];
}

- (void)setObject:(id)object forKey:(NSString*)key {
	[self setObject:object forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}   

- (void)setObject:(id)object forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache {
	[self setObject:object forKey:key withTimeoutInterval:self.defaultTimeoutInterval useMemoryCache:useMemoryCache];
}   

- (void)setObject:(id)object forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval {
	[self setObject:object forKey:key withTimeoutInterval:timeoutInterval useMemoryCache:self.defaultUseMemoryCache];
}

- (void)setObject:(id)object forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache {
    [self setData:[NSKeyedArchiver archivedDataWithRootObject:object] forKey:key withTimeoutInterval:timeoutInterval memoryCachedObject:(useMemoryCache ? object : nil)];
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
#if EGO_CACHE_USE_NS_CACHE
#else
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    [memoryCache release];
	[diskOperationQueue release];
	[cacheDictionary release];
	[super dealloc];
}

@end