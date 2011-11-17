//
//  EGOCache.h
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

#import <Foundation/Foundation.h>

#ifndef EGO_CACHE_USE_NS_CACHE
#define EGO_CACHE_USE_NS_CACHE 1
#endif

@interface EGOCache : NSObject {
@private
	NSMutableDictionary* cacheDictionary;
	NSOperationQueue* diskOperationQueue;
	NSTimeInterval defaultTimeoutInterval;
#if EGO_CACHE_USE_NS_CACHE
    NSCache *memoryCache;
#else
    NSMutableDictionary *memoryCache;
#endif
    BOOL defaultUseMemoryCache;
}

+ (EGOCache*)currentCache;
+ (NSString*)keyForPrefix:(NSString*)prefix url:(NSURL*)url;
+ (NSString*)keyForPrefix:(NSString*)prefix string:(NSString*)string;

- (void)clearCache;
- (void)clearMemoryCache;
- (void)removeCacheForKey:(NSString*)key;
- (void)removeMemoryCacheForKey:(NSString*)key;

- (BOOL)hasCacheForKey:(NSString*)key;
- (BOOL)hasCacheForKey:(NSString*)key checkOnlyMemory:(BOOL) memoryOnly;

- (NSData*)dataForKey:(NSString*)key;
- (NSData*)dataForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setData:(NSData*)data forKey:(NSString*)key;
- (void)setData:(NSData*)data forKey:(NSString*)key memoryCachedObject:(id)object;
- (void)setData:(NSData*)data forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval;
- (void)setData:(NSData*)data forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval memoryCachedObject:(id)object;

- (NSString*)stringForKey:(NSString*)key;
- (NSString*)stringForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setString:(NSString*)aString forKey:(NSString*)key;
- (void)setString:(NSString*)aString forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setString:(NSString*)aString forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval;
- (void)setString:(NSString*)aString forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache;

#if TARGET_OS_IPHONE
- (UIImage*)imageForKey:(NSString*)key;
- (UIImage*)imageForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setImage:(UIImage*)anImage forKey:(NSString*)key;
- (void)setImage:(UIImage*)anImage forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setImage:(UIImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval;
- (void)setImage:(UIImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache;
#else
- (NSImage*)imageForKey:(NSString*)key
- (NSImage*)imageForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setImage:(NSImage*)anImage forKey:(NSString*)key;
- (void)setImage:(NSImage*)anImage forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setImage:(NSImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval;
- (void)setImage:(NSImage*)anImage forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache;
#endif

- (id)plistForKey:(NSString*)key;
- (id)plistForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setPlist:(id)plistObject forKey:(NSString*)key;
- (void)setPlist:(id)plistObject forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setPlist:(id)plistObject forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval;
- (void)setPlist:(id)plistObject forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache;

- (id)objectForKey:(NSString*)key;
- (id)objectForKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setObject:(id)object forKey:(NSString*)key;
- (void)setObject:(id)object forKey:(NSString*)key useMemoryCache:(BOOL)useMemoryCache;
- (void)setObject:(id)object forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval;
- (void)setObject:(id)object forKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval useMemoryCache:(BOOL)useMemoryCache;

- (void)copyFilePath:(NSString*)filePath asKey:(NSString*)key;
- (void)copyFilePath:(NSString*)filePath asKey:(NSString*)key withTimeoutInterval:(NSTimeInterval)timeoutInterval;	

@property(nonatomic,assign) NSTimeInterval defaultTimeoutInterval;  // Default is 1 day
@property(nonatomic,assign) BOOL defaultUseMemoryCache;             // Default is YES
@end