////////////////////////////////////////////////////////////////////////////////
//
//  TYPHOON FRAMEWORK
//  Copyright 2013, Jasper Blues & Contributors
//  All Rights Reserved.
//
//  NOTICE: The authors permit you to use, modify, and distribute this file
//  in accordance with the terms of the license agreement accompanying it.
//
////////////////////////////////////////////////////////////////////////////////


#import "TyphoonAssemblySelectorAdviser.h"
#import "TyphoonAssemblyAdviser.h"
#import "TyphoonAssembly.h"
#import "TyphoonJRSwizzle.h"
#import <objc/runtime.h>
#import "TyphoonAssembly+TyphoonAssemblyFriend.h"
#import "OCLogTemplate.h"
#import "TyphoonWrappedSelector.h"
#import "TyphoonJRMethodSwizzler.h"

static NSMutableDictionary* swizzledDefinitionsByAssemblyClass;

@interface TyphoonAssemblyAdviser()

@end


@implementation TyphoonAssemblyAdviser
{

}

+ (void)initialize
{
    @synchronized (self)
    {
        swizzledDefinitionsByAssemblyClass = [[NSMutableDictionary alloc] init];
    }
}

- (id)initWithAssembly:(TyphoonAssembly*)assembly
{
    self = [super init];
    if (self) {
        _assembly = assembly;

        _swizzler = [[TyphoonJRMethodSwizzler alloc] init];
    }
    return self;
}

#pragma mark - Advising
- (void)adviseAssembly
{
    @synchronized (self)
    {
        if ([TyphoonAssemblyAdviser assemblyIsNotAdvised:self.assembly])
        {
            [self swizzleAssemblyMethods];
        }
    }
}

- (void)swizzleAssemblyMethods
{
    NSSet* definitionSelectors = [self enumerateDefinitionSelectors];
    NSLog(@"About to swizzle the following definition selectors: %@.", definitionSelectors);

    [self swizzleDefinitionSelectors:definitionSelectors];

    [[self class] markAssemblyMethods:definitionSelectors asAdvised:self.assembly];
}

- (void)swizzleDefinitionSelectors:(NSSet*)definitionSelectors
{
    [definitionSelectors enumerateObjectsUsingBlock:^(NSValue *selectorObj, BOOL* stop)
    {
        [self swapImplementationOfDefinitionSelectorWithAdvisedImplementation:selectorObj];
    }];
}

- (void)swapImplementationOfDefinitionSelectorWithAdvisedImplementation:(TyphoonWrappedSelector*)wrappedSEL
{
    SEL methodSelector = [wrappedSEL selector];
    SEL swizzled = [TyphoonAssemblySelectorAdviser advisedSELForSEL:methodSelector];

    NSError* err;
    BOOL success = [self.swizzler swizzleMethod:methodSelector withMethod:swizzled onClass:[self.assembly class] error:&err];
    if (!success) {
        LogError(@"Failed to swizzle method '%@' on class '%@' with method '%@'.", NSStringFromSelector(methodSelector), NSStringFromClass([self.assembly class]), NSStringFromSelector(swizzled));
        LogError(@"'%@'", err);
        [NSException raise:NSInternalInconsistencyException format:@"Failed to swizzle method, everything is broken!"];
    }
}

+ (void)undoAdviseMethods:(TyphoonAssembly*)assembly
{
    @synchronized (self)
    {
        if ([TyphoonAssemblyAdviser assemblyIsAdvised:assembly])
        {
            [self unswizzleAssemblyMethods:assembly];
        }
    }
}

+ (void)unswizzleAssemblyMethods:(TyphoonAssembly*)assembly
{
    NSSet* swizzledSelectors = [swizzledDefinitionsByAssemblyClass objectForKey:NSStringFromClass([assembly class])];

    LogTrace(@"Unswizzling the following selectors: '%@' on assembly: '%@'.", [self humanReadableDescriptionForSelectorObjects:swizzledSelectors], assembly);

    [self swizzleDefinitionSelectors:swizzledSelectors onAssembly:assembly];

    [self markAssemblyMethodsAsNoLongerAdvised:assembly];
}

+ (NSString*)humanReadableDescriptionForSelectorObjects:(NSSet*)selectors
{
    NSMutableSet* selectorStrings = [[NSMutableSet alloc] initWithCapacity:selectors.count];
    [selectors enumerateObjectsUsingBlock:^(NSValue* obj, BOOL* stop)
    {
        SEL sel = [obj pointerValue];
        NSString* string = NSStringFromSelector(sel);
        [selectorStrings addObject:string];
    }];

    return [selectorStrings description];
}

+ (void)swizzleAssemblyMethods:(TyphoonAssembly*)assembly
{
    NSSet* definitionSelectors = [assembly definitionSelectors];
    LogTrace(@"About to swizzle the following methods: %@.", [self humanReadableDescriptionForSelectorObjects:definitionSelectors]);

    [self swizzleDefinitionSelectors:definitionSelectors onAssembly:assembly];

    [self markAssemblyMethods:definitionSelectors asAdvised:assembly];
}

+ (void)swizzleDefinitionSelectors:(NSSet*)definitionSelectors onAssembly:(TyphoonAssembly*)assembly
{
    [definitionSelectors enumerateObjectsUsingBlock:^(TyphoonWrappedSelector* selectorObj, BOOL* stop)
    {
        [self swapImplementationOfDefinitionSelector:selectorObj withDynamicBeforeAdviceImplementationOnAssembly:assembly];
    }];
}

+ (void)swapImplementationOfDefinitionSelector:(TyphoonWrappedSelector*)wrappedSelector withDynamicBeforeAdviceImplementationOnAssembly:(TyphoonAssembly*)assembly
{
    return [self swapImplementationOfDefinitionSelector:wrappedSelector withDynamicBeforeAdviceImplementationOnAssemblyClass:[assembly class]];
}

+ (void)swapImplementationOfDefinitionSelector:(TyphoonWrappedSelector*)wrappedSEL withDynamicBeforeAdviceImplementationOnAssemblyClass:(Class)assemblyClass
{
    SEL methodSelector = [wrappedSEL selector];
    SEL swizzled = [TyphoonAssemblySelectorAdviser advisedSELForSEL:methodSelector];

    NSError* err;
    BOOL success = [assemblyClass typhoon_swizzleMethod:methodSelector withMethod:swizzled error:&err];
    if (!success)
    {
        LogError(@"Failed to swizzle method '%@' on class '%@' with method '%@'.", NSStringFromSelector(methodSelector), NSStringFromClass(assemblyClass), NSStringFromSelector(swizzled));
        LogError(@"'%@'", err);
        [NSException raise:NSInternalInconsistencyException format:@"Failed to swizzle method, everything is broken!"];
    }
}

#pragma mark - Definition Selector Enumerator
- (NSSet*)enumerateDefinitionSelectors
{
    NSMutableSet* definitionSelectors = [[NSMutableSet alloc] init];
    [self addDefinitionSelectorsForSubclassesOfAssemblyToSet:definitionSelectors];
    return definitionSelectors;
}

- (void)addDefinitionSelectorsForSubclassesOfAssemblyToSet:(NSMutableSet*)definitionSelectors
{
    Class currentClass = [self.assembly class];
    while ([self classNotRootAssemblyClass:currentClass])
    {
        [definitionSelectors unionSet:[self obtainDefinitionSelectorsInAssemblyClass:currentClass]];
        currentClass = class_getSuperclass(currentClass);
    }
}

- (BOOL)classNotRootAssemblyClass:(Class)class
{
    NSString* currentClassName = NSStringFromClass(class);
    NSString* rootAssemblyClassName = NSStringFromClass([TyphoonAssembly class]);

    return ![currentClassName isEqualToString:rootAssemblyClassName];
}

- (NSSet*)obtainDefinitionSelectorsInAssemblyClass:(Class)pClass
{
    NSMutableSet* definitionSelectors = [[NSMutableSet alloc] init];
    [self addDefinitionSelectorsInClass:pClass toSet:definitionSelectors];
    return definitionSelectors;
}

- (void)addDefinitionSelectorsInClass:(Class)aClass toSet:(NSMutableSet*)definitionSelectors
{
    [self enumerateMethodsInClass:aClass usingBlock:^(Method method)
    {
        if ([self method:method onClassIsNotReserved:aClass] && [self method:method onClassIsNotAdvised:aClass])
        {
            [self addDefinitionSelectorForMethod:method toSet:definitionSelectors];
        }
    }];
}

typedef void(^MethodEnumerationBlock)(Method method);

- (void)enumerateMethodsInClass:(Class)class usingBlock:(MethodEnumerationBlock)block;
{
    unsigned int methodCount;
    Method* methodList = class_copyMethodList(class, &methodCount);
    for (int i = 0; i < methodCount; i++)
    {
        Method method = methodList[i];
        block(method);
    }
    free(methodList);
}

- (BOOL)method:(Method)method onClassIsNotReserved:(Class)aClass
{
    SEL methodSelector = method_getName(method);
    return ![aClass selectorReservedOrPropertySetter:methodSelector];
}

- (BOOL)method:(Method)pMethod onClassIsNotAdvised:(Class)advised
{
    SEL sel = method_getName(pMethod);
    return ![TyphoonAssemblySelectorAdviser selectorIsAdvised:sel];
}

- (void)addDefinitionSelectorForMethod:(Method)method toSet:(NSMutableSet*)definitionSelectors
{
    SEL methodSelector = method_getName(method);
    TyphoonWrappedSelector* wrappedSEL = [TyphoonWrappedSelector wrappedSelectorWithSelector:methodSelector];
    [definitionSelectors addObject:wrappedSEL];
}

#pragma mark - Advising Registry
+ (BOOL)assemblyIsNotAdvised:(TyphoonAssembly*)assembly;
{
    return ![self assemblyIsAdvised:assembly];
}

+ (BOOL)assemblyIsAdvised:(TyphoonAssembly*)assembly
{
    return [self assemblyClassIsAdvised:[assembly class]];
}

+ (BOOL)assemblyClassIsAdvised:(Class)class
{
    NSLog(@"Checking if assemby class is advised: '%@'.", NSStringFromClass(class));

    return [[swizzledDefinitionsByAssemblyClass allKeys] containsObject:NSStringFromClass(class)];
}

+ (void)markAssemblyMethods:(NSSet*)definitionSelectors asAdvised:(TyphoonAssembly*)assembly;
{
    [swizzledDefinitionsByAssemblyClass setObject:definitionSelectors forKey:NSStringFromClass([assembly class])];
}

+ (void)markAssemblyMethodsAsNoLongerAdvised:(TyphoonAssembly*)assembly;
{
    [swizzledDefinitionsByAssemblyClass removeObjectForKey:NSStringFromClass([assembly class])];
}

@end
