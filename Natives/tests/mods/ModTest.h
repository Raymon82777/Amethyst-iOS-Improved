// Minimal host-side test harness for the Foundation-only mod manager classes.
// Built and run on macOS via `make test_mods`; never part of the app target.
#import <Foundation/Foundation.h>

extern int gModTestFailures;

#define MT_ASSERT(cond) \
    do { \
        if (!(cond)) { \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gModTestFailures++; \
        } \
    } while (0)

// Compares with isEqual:, treating two nils as equal.
#define MT_EQUAL(a, b) \
    do { \
        id mt_a = (a); \
        id mt_b = (b); \
        if (!(mt_a == mt_b || [mt_a isEqual:mt_b])) { \
            const char *mt_as = [[mt_a description] UTF8String]; \
            const char *mt_bs = [[mt_b description] UTF8String]; \
            fprintf(stderr, "FAIL %s:%d: %s == %s\n  actual:   %s\n  expected: %s\n", \
                __FILE__, __LINE__, #a, #b, mt_as ? mt_as : "(nil)", mt_bs ? mt_bs : "(nil)"); \
            gModTestFailures++; \
        } \
    } while (0)

#define MT_RUN(fn) \
    do { \
        printf("RUN  %s\n", #fn); \
        fn(); \
    } while (0)
