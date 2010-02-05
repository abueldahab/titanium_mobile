/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2009-2010 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */

#import <objc/runtime.h>

#import "TiProxy.h"
#import "TiHost.h"
#import "KrollCallback.h"
#import "KrollBridge.h"
#import "TiModule.h"

//Common exceptions to throw when the function call was improper
NSString * const TiExceptionInvalidType = @"Invalid type passed to function";
NSString * const TiExceptionNotEnoughArguments = @"Invalid number of arguments to function";
NSString * const TiExceptionRangeError = @"Value passed to function exceeds allowed range";

//Should be rare, but also useful if arguments are used improperly.
NSString * const TiExceptionInternalInconsistency = @"Value was not the value expected";

//Rare exceptions to indicate a bug in the titanium code (Eg, method that a subclass should have implemented)
NSString * const TiExceptionUnimplementedFunction = @"Subclass did not implement required method";


static int tiProxyId = 0;


@implementation TiProxy

@synthesize pageContext, executionContext, proxyId;
@synthesize modelDelegate;


#pragma mark Private

-(id)init
{
	if (self = [super init])
	{
#if PROXY_MEMORY_TRACK == 1
		NSLog(@"INIT: %@ (%d)",self,[self hash]);
#endif
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(didReceiveMemoryWarning:)
													 name:UIApplicationDidReceiveMemoryWarningNotification  
												   object:nil]; 
		
		modelDelegate = nil;
		pageContext = nil;
		executionContext = nil;
		destroyLock = [[NSRecursiveLock alloc] init];
	}
	return self;
}

-(id)_initWithPageContext:(id<TiEvaluator>)context
{
	if (self = [self init])
	{
		pageContext = (id)context; // do not retain 
		proxyId = [[NSString stringWithFormat:@"proxy$%d",tiProxyId++] retain];

		contextListeners = [[NSMutableDictionary alloc] init];
		if (context!=nil)
		{
			[[NSNotificationCenter defaultCenter] addObserver:self 
													 selector:@selector(contextShutdown:) 
														 name:kKrollShutdownNotification 
													   object:pageContext];
			
			[contextListeners setObject:pageContext forKey:[pageContext description]];
		}
		
		// register our proxy
		[[pageContext host] registerProxy:self];

		// allow subclasses to configure themselves
		[self _configure];
	}
	return self;
}

-(void)contextWasShutdown:(KrollBridge*)bridge
{
}

-(void)contextShutdown:(NSNotification*)sender
{
	KrollBridge *bridge = (KrollBridge*)[sender object];
	if (contextListeners!=nil)
	{
		id key = [bridge description];
		id value = [contextListeners objectForKey:key];
		if (value!=nil)
		{
			[[NSNotificationCenter defaultCenter] removeObserver:self 
															name:kKrollShutdownNotification 
														  object:value];
		
			[contextListeners removeObjectForKey:key];
			
			// remove any listeners that match this context being destroyed that we have registered
			if (listeners!=nil)
			{
				for (id type in [NSDictionary dictionaryWithDictionary:listeners])
				{
					NSArray *a = [listeners objectForKey:type];
					for (KrollCallback *callback in [NSArray arrayWithArray:a])
					{
						if ([bridge krollContext] == [callback context])
						{
							[self removeEventListener:[NSArray arrayWithObjects:type,callback,nil]];
						}
					}
				}
			}
			
			[self _destroy];
			[self _contextDestroyed];
		}
	}
	[self contextWasShutdown:bridge];
}

-(void)setExecutionContext:(id<TiEvaluator>)context
{
	// the execution context is different than the page context
	//
	// the page context is the owning context that created (and thus owns) the proxy
	//
	// the execution context is the context which is executing against the context when 
	// this proxy is being touched.  since objects can be referenced from one context 
	// in another, the execution context should be used to resolve certain things like
	// paths, etc. so that the proper context can be contextualized which is different
	// than the owning context (page context).
	//
	executionContext = context; //don't retain
}

-(void)_initWithProperties:(NSDictionary*)properties
{
	for (id key in properties)
	{
		id value = [properties objectForKey:key];
		if (value == [NSNull null])
		{
			value = nil;
		}
		[self setValue:value forKey:key];
	}	
}

-(void)_initWithCallback:(KrollCallback*)callback
{
}

-(void)_configure
{
	// for subclasses
}

-(id)_initWithPageContext:(id<TiEvaluator>)context_ args:(NSArray*)args
{
	if (self = [self _initWithPageContext:context_])
	{
		id a = nil;
		int count = [args count];
		
		if (count > 0 && [[args objectAtIndex:0] isKindOfClass:[NSDictionary class]])
		{
			a = [args objectAtIndex:0];
		}
		
		if (count > 1 && [[args objectAtIndex:1] isKindOfClass:[KrollCallback class]])
		{
			[self _initWithCallback:[args objectAtIndex:1]];
		}
		
		if (![NSThread isMainThread] && [self _propertyInitRequiresUIThread])
		{
			[self performSelectorOnMainThread:@selector(_initWithProperties:) withObject:a waitUntilDone:NO];
		}		
		else 
		{
			[self _initWithProperties:a];
		}
	}
	return self;
}

-(void)_contextDestroyed
{
}

-(void)_destroy
{
	[destroyLock lock];
	
	if (destroyed)
	{
		[destroyLock unlock];
		return;
	}
	
	destroyed = YES;
	
#if PROXY_MEMORY_TRACK == 1
	NSLog(@"DESTROY: %@ (%d)",self,[self hash]);
#endif
	[[NSNotificationCenter defaultCenter] removeObserver:self
													name:UIApplicationDidReceiveMemoryWarningNotification  
												  object:nil];  
	
	if (executionContext!=nil)
	{
		[[NSNotificationCenter defaultCenter] removeObserver:self 
												 name:kKrollShutdownNotification 
												   object:executionContext];
		executionContext = nil;
	}
	
	// remove all listeners JS side proxy
	if (listeners!=nil)
	{
		if (pageContext!=nil)
		{
			TiHost *host = [self _host];
			if (host!=nil)
			{
				for (id type in listeners)
				{
					NSArray *array = [listeners objectForKey:type];
					for (id listener in array)
					{
						[host removeListener:listener context:pageContext];
					}
				}
			}
		}
		[listeners removeAllObjects];
		[listeners release];
		listeners = nil;
	}
	if (contextListeners!=nil)
	{
		for (id key in contextListeners)
		{
			id value = [contextListeners objectForKey:key];
			[[NSNotificationCenter defaultCenter] removeObserver:self 
															name:kKrollShutdownNotification 
														  object:value];
		}
		[contextListeners removeAllObjects];
	}
	if (pageContext!=nil && proxyId!=nil)
	{
		[[self _host] unregisterProxy:proxyId];
		proxyId = nil;
	}
	[dynprops removeAllObjects];
	[listeners removeAllObjects];
	RELEASE_TO_NIL(proxyId);
	RELEASE_TO_NIL(dynprops);
	RELEASE_TO_NIL(listeners);
	RELEASE_TO_NIL(baseURL);
	RELEASE_TO_NIL(krollDescription);
	RELEASE_TO_NIL(contextListeners);
	pageContext=nil;
	modelDelegate=nil;
	[destroyLock unlock];
}

-(void)dealloc
{
#if PROXY_MEMORY_TRACK == 1
	NSLog(@"DEALLOC: %@ (%d)",self,[self hash]);
#endif
	[self _destroy];
	RELEASE_TO_NIL(destroyLock);
	[super dealloc];
}

-(TiHost*)_host
{
	if (pageContext==nil && executionContext==nil)
	{
		return nil;
	}
	if (pageContext!=nil)
	{
		TiHost *h = [pageContext host];
		if (h!=nil)
		{
			return h;
		}
	}
	if (executionContext!=nil)
	{
		return [executionContext host];
	}
	return nil;
}

-(TiProxy*)currentWindow
{
	return [[self pageContext] preloadForKey:@"currentWindow"];
}

-(NSURL*)_baseURL
{
	if (baseURL==nil)
	{
		TiProxy *currentWindow = [self currentWindow];
		if (currentWindow!=nil)
		{
			// cache it
			[self _setBaseURL:[currentWindow _baseURL]];
			return baseURL;
		}
		return [[self _host] baseURL];
	}
	return baseURL;
}

-(void)_setBaseURL:(NSURL*)url
{
	RELEASE_TO_NIL(baseURL);
	baseURL = [[url absoluteURL] retain];
}

-(BOOL)_hasListeners:(NSString*)type
{
	return listeners!=nil && [listeners objectForKey:type]!=nil;
}

-(void)_willChangeValue:(id)property value:(id)value
{
	// called before a dynamic property is set against this instance
	// the value is the old value before the change
}

-(void)_diChangeValue:(id)property value:(id)value
{
	// called after a dynamic property is set againt this instance
	// the value is the new value after the change
}

-(void)_fireEventToListener:(NSString*)type withObject:(id)obj listener:(KrollCallback*)listener thisObject:(TiProxy*)thisObject_
{
	[destroyLock lock];
	
	TiHost *host = [self _host];
	
	NSMutableDictionary* eventObject = nil;
	if ([obj isKindOfClass:[NSDictionary class]])
	{
		eventObject = [NSMutableDictionary dictionaryWithDictionary:obj];
	}
	else 
	{
		eventObject = [NSMutableDictionary dictionary];
	}
	
	// common event properties for all events we fire
	[eventObject setObject:type forKey:@"type"];
	[eventObject setObject:self forKey:@"source"];
	
	id<TiEvaluator> evaluator = (id<TiEvaluator>)[listener context].delegate;
	[host fireEvent:listener withObject:eventObject remove:NO context:evaluator thisObject:thisObject_];
	
	[destroyLock unlock];
}

-(void)_listenerAdded:(NSString*)type count:(int)count
{
	// for subclasses
}

-(void)_listenerRemoved:(NSString*)type count:(int)count
{
	// for subclasses
}

// this method will allow a proxy to return a different object back
// for itself when the proxy serialization occurs from native back
// to the bridge layer - the default is to just return ourselves, however,
// in some concrete implementations you really want to return a different
// representation which this will allow. the resulting value should not be 
// retained
-(id)_proxy:(TiProxyBridgeType)type
{
	return self;
}

#pragma mark Public

-(id<NSFastEnumeration>)validKeys
{
	return nil;
}

-(void)addEventListener:(NSArray*)args
{
	NSString *type = [args objectAtIndex:0];
	KrollCallback* listener = [args objectAtIndex:1];
	ENSURE_TYPE(listener,KrollCallback);
	
	if (listeners==nil)
	{
		listeners = [[NSMutableDictionary alloc]init];
	}

	NSMutableArray *l = [listeners objectForKey:type];
	if (l==nil)
	{
		l = [[NSMutableArray alloc] init];
		[listeners setObject:l forKey:type];
		[l release];
	}
	
	// we need to listener for the execution context shutdown in the case it's not the 
	// same as our pageContext. we basically will then remove the listener
	if (pageContext!=executionContext)
	{
		id key = [executionContext description];
		id found = [contextListeners objectForKey:key];
		if (found==nil)
		{
			[[NSNotificationCenter defaultCenter] addObserver:self 
													 selector:@selector(contextShutdown:) 
														 name:kKrollShutdownNotification 
													   object:executionContext];	
			[contextListeners setObject:executionContext forKey:key];
		}
	}
	
	[l addObject:listener];
	[self _listenerAdded:type count:[l count]];
}
	  
-(void)removeEventListener:(NSArray*)args
{
	NSString *type = [args objectAtIndex:0];
	KrollCallback *listener = [args objectAtIndex:1];

	NSMutableArray *l = [listeners objectForKey:type];
	if (l!=nil && [l count]>0)
	{
		[l removeObject:listener];
		
		// once empty, remove the object
		if ([l count]==0)
		{
			[listeners removeObjectForKey:type];
		}
		
		// once we have no more listeners, release memory!
		if ([listeners count]==0)
		{
			[listeners autorelease];
			listeners = nil;
		}
	}
	id<TiEvaluator> ctx = (id<TiEvaluator>)[listener context];
	[[self _host] removeListener:listener context:ctx];
	[self _listenerRemoved:type count:[l count]];
}
	  
-(void)fireEvent:(NSString*)type withObject:(id)obj
{
	[destroyLock lock];
	
	if (listeners!=nil)
	{
		NSMutableArray *l = [listeners objectForKey:type];
		if (l!=nil)
		{
			TiHost *host = [self _host];
			
			NSMutableDictionary* eventObject = nil;
			if ([obj isKindOfClass:[NSDictionary class]])
			{
				eventObject = [NSMutableDictionary dictionaryWithDictionary:obj];
			}
			else 
			{
				eventObject = [NSMutableDictionary dictionary];
			}
			
			// common event properties for all events we fire
			[eventObject setObject:type forKey:@"type"];
			[eventObject setObject:self forKey:@"source"];
			
			// unfortunately we have to make a copy to be able to mutate and still iterate
			NSMutableArray *_listeners = [NSMutableArray arrayWithArray:l];
			for (KrollCallback* listener in _listeners)
			{
				id<TiEvaluator> evaluator = (id<TiEvaluator>)[listener context].delegate;
				if ([[listener context] running])
				{
					[host fireEvent:listener withObject:eventObject remove:NO context:evaluator thisObject:nil];
				}
				else
				{
					// this happens when we have stored an event callback for a context that has
					// been shutdown... in this case, we go ahead and remove the listener and clean
					// up the listener
					[l removeObject:listener];
					[[self _host] removeListener:listener context:pageContext];
					[self _listenerRemoved:type count:[l count]];
				}
			}
			// if we ended up removing all our listeners
			if ([l count]==0)
			{
				[listeners removeObjectForKey:type];
			}
		}
	}
	[destroyLock unlock];
}

- (void)setValuesForKeysWithDictionary:(NSDictionary *)keyedValues usingKeys:(id<NSFastEnumeration>)keys;
{
	for (NSString * thisKey in keys)
	{
		id thisValue = [keyedValues objectForKey:thisKey];
		if (thisValue == nil) //Dictionary doesn't have this key. Skip.
		{
			continue;
		}
		if (thisValue == [NSNull null]) 
		{ 
			//When a null, we want to write a nil.
			thisValue = nil;
		}
		[self setValue:thisValue forKey:thisKey];
	}
}
 
DEFINE_EXCEPTIONS


-(BOOL)_propertyInitRequiresUIThread
{
	// tell our constructor not to place _initWithProperties on UI thread by default
	return NO;
}

- (id) valueForUndefinedKey: (NSString *) key
{
	if ([key isEqualToString:@"toString"] || [key isEqualToString:@"valueOf"])
	{
		return [self description];
	}
	if (dynprops != nil)
	{
		return [dynprops objectForKey:key];
	}
	//NOTE: we need to return nil here since in JS you can ask for properties
	//that don't exist and it should return undefined, not an exception
	return nil;
}

- (void) replaceValue:(id)value forKey:(NSString*)key notification:(BOOL)notify
{
	// used for replacing a value and controlling model delegate notifications
	if (value==nil)
	{
		value = [NSNull null];
	}
	id current = nil;
	if (dynprops==nil)
	{
		dynprops = [[NSMutableDictionary alloc] init];
	}
	else
	{
		// hold it for this invocation since set may cause it to be deleted
		current = [dynprops objectForKey:key];
		if (current!=nil)
		{
			current = [[current retain] autorelease];
		}
	}
	if ((current!=value)&&![current isEqual:value])
	{
		[dynprops setValue:value forKey:key];
	}
	
	if (notify && self.modelDelegate!=nil)
	{
		[self.modelDelegate propertyChanged:key oldValue:current newValue:value proxy:self];
	}
}

- (void) setValue:(id)value forUndefinedKey: (NSString *) key
{
	// if the object specifies a validKeys set, we enforce setting against only those keys
	if (self.validKeys!=nil)
	{
		if ([(id)self.validKeys containsObject:key]==NO)
		{
			[self throwException:[NSString stringWithFormat:@"property '%@' not supported",key] subreason:nil location:CODELOCATION];
		}
	}
	
	id current = nil;
	if (dynprops!=nil)
	{
		// hold it for this invocation since set may cause it to be deleted
		current = [[[dynprops objectForKey:key] retain] autorelease];
		if (current==[NSNull null])
		{
			current = nil;
		}
	}
	else
	{
		//TODO: make this non-retaining?
		dynprops = [[NSMutableDictionary alloc] init];
	}

	id propvalue = value;
	
	if (value == nil)
	{
		propvalue = [NSNull null];
	}
	else if (value == [NSNull null])
	{
		value = nil;
	}
		
	// notify our delegate
	if (current!=value)
	{
		[dynprops setValue:propvalue forKey:key];
		if (self.modelDelegate!=nil)
		{
			[[(NSObject*)self.modelDelegate retain] autorelease];
			[self.modelDelegate propertyChanged:key oldValue:current newValue:value proxy:self];
		}
	}
}

-(NSDictionary*)allProperties
{
	return dynprops;
}

#pragma mark KrollDynamicMethodProxy

-(id)resultForUndefinedMethod:(NSString*)name args:(NSArray*)args
{
	// by default, the base model class will just raise an exception
	NSString *msg = [NSString stringWithFormat:@"method named '%@' not supported against %@",name,self];
	NSLog(@"[WARN] %@",msg);
	[self throwException:msg subreason:nil location:CODELOCATION];
	return nil;
}

#pragma mark Memory Management
-(void)didReceiveMemoryWarning:(NSNotification*)notification
{
	//FOR NOW, we're not dropping anything but we'll want to do before release
	//subclasses need to call super if overriden
}

#pragma mark Dispatching Helper

-(void)_dispatchWithObjectOnUIThread:(NSArray*)args
{
	//NOTE: this is called by ENSURE_UI_THREAD_WITH_OBJ and will always be on UI thread when we get here
	id method = [args objectAtIndex:0];
	id firstobj = [args count] > 1 ? [args objectAtIndex:1] : nil;
	id secondobj = [args count] > 2 ? [args objectAtIndex:2] : nil;
	if (firstobj == [NSNull null])
	{
		firstobj = nil;
	}
	if (secondobj == [NSNull null])
	{
		secondobj = nil;
	}
	SEL selector = NSSelectorFromString([NSString stringWithFormat:@"%@:withObject:",method]);
	[self performSelector:selector withObject:firstobj withObject:secondobj];
}

#pragma mark Description for nice toString in JS

-(id)toString
{
	if (krollDescription==nil)
	{
		NSString *cn = [[self class] description];
		krollDescription = [[NSString stringWithFormat:@"[object %@]",[cn stringByReplacingOccurrencesOfString:@"Proxy" withString:@""]] retain];
	}

	return krollDescription;
}

-(id)description
{
	return [self toString];
}

-(id)toJSON
{
	// this is called in the case you try and use JSON.stringify and an object is a proxy 
	// since you can't serialize a proxy as JSON, just return null
	return [NSNull null];
}

@end
