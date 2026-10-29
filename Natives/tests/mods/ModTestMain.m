#import "ModTest.h"

int gModTestFailures = 0;

// One entry point per test file; later tasks append here.
void ModIndexTests(void);
void ModProfileInfoTests(void);
void ModVersionSelectorTests(void);
void ModFolderTests(void);
void ModDependencyResolverTests(void);

int main(void) {
    @autoreleasepool {
        ModIndexTests();
        ModProfileInfoTests();
        ModVersionSelectorTests();
        ModFolderTests();
        ModDependencyResolverTests();
    }
    if (gModTestFailures > 0) {
        fprintf(stderr, "%d assertion(s) failed\n", gModTestFailures);
        return 1;
    }
    printf("All mod tests passed\n");
    return 0;
}
