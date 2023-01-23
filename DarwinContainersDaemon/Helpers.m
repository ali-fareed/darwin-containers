#include "DarwinContainersDaemon-Bridging-Header.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

void swizzleInstanceMethodOfClass(Class targetClass, SEL currentSelector, SEL newSelector) {
    Method origMethod = nil, newMethod = nil;
    
    origMethod = class_getInstanceMethod(targetClass, currentSelector);
    newMethod = class_getInstanceMethod(targetClass, newSelector);
    if ((origMethod != nil) && (newMethod != nil)) {
        if (class_addMethod(targetClass, currentSelector, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
            class_replaceMethod(targetClass, newSelector, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
        } else {
            method_exchangeImplementations(origMethod, newMethod);
        }
    }
}

@interface _VZKeyEvent (Swizzled)

@end

@implementation _VZKeyEvent (Swizzled)

- (instancetype)swizzled_initWithType:(VZKeyEventType)type keyCode:(unsigned short)keyCode {
    if (type == VZKeyEventTypeDown) {
        //printf("_VZKeyEvent code: %d\n", (int)keyCode);
    }
    return [self swizzled_initWithType:type keyCode:keyCode];
}

@end

@interface _VZScreenCoordinatePointerEvent (Swizzled)

@end

@implementation _VZScreenCoordinatePointerEvent (Swizzled)

- (instancetype)swizzled_initWithLocation:(CGPoint)location pressedButtons:(unsigned short)pressedButtons {
    //printf("mouse (%f, %f) — %d\n", location.x, location.y, (int)pressedButtons);
    return [self swizzled_initWithLocation:location pressedButtons:pressedButtons];
}

@end

void swizzleRuntimeMethods(void) {
    swizzleInstanceMethodOfClass([_VZKeyEvent class], @selector(initWithType:keyCode:), @selector(swizzled_initWithType:keyCode:));
    swizzleInstanceMethodOfClass([_VZScreenCoordinatePointerEvent class], @selector(initWithLocation:pressedButtons:), @selector(swizzled_initWithLocation:pressedButtons:));
}

void DumpObjcMethods(Class clazz) {
    {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(clazz, &methodCount);
        
        printf("Found %d methods on '%s'\n", methodCount, class_getName(clazz));
        
        for (unsigned int i = 0; i < methodCount; i++) {
            Method method = methods[i];
            
            printf("\t'%s' has method named '%s' of encoding '%s'\n",
                   class_getName(clazz),
                   sel_getName(method_getName(method)),
                   method_getTypeEncoding(method));
            
            /**
             *  Or do whatever you need here...
             */
        }
        
        free(methods);
    }
    
    u_int count;
        
        Ivar* ivars = class_copyIvarList(clazz, &count);
        NSMutableArray* ivarArray = [NSMutableArray arrayWithCapacity:count];
        for (int i = 0; i < count ; i++)
        {
            const char* ivarName = ivar_getName(ivars[i]);
            [ivarArray addObject:[NSString  stringWithCString:ivarName encoding:NSUTF8StringEncoding]];
        }
        free(ivars);
        
        objc_property_t* properties = class_copyPropertyList(clazz, &count);
        NSMutableArray* propertyArray = [NSMutableArray arrayWithCapacity:count];
        for (int i = 0; i < count ; i++)
        {
            const char* propertyName = property_getName(properties[i]);
            [propertyArray addObject:[NSString  stringWithCString:propertyName encoding:NSUTF8StringEncoding]];
        }
        free(properties);
        
        Method* methods = class_copyMethodList(clazz, &count);
        NSMutableArray* methodArray = [NSMutableArray arrayWithCapacity:count];
        for (int i = 0; i < count ; i++)
        {
            SEL selector = method_getName(methods[i]);
            const char* methodName = sel_getName(selector);
            [methodArray addObject:[NSString  stringWithCString:methodName encoding:NSUTF8StringEncoding]];
        }
        free(methods);
        
        NSDictionary* classDump = [NSDictionary dictionaryWithObjectsAndKeys:
                                   ivarArray, @"ivars",
                                   propertyArray, @"properties",
                                   methodArray, @"methods",
                                   nil];
        
        NSLog(@"%@", classDump);
}
