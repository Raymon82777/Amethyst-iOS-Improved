#import "ModTest.h"

int gModTestFailures = 0;

// One entry point per test file; later tasks append here.
void ModIndexTests(void);
void ModProfileInfoTests(void);
void ModVersionSelectorTests(void);
void ModFolderTests(void);
void ModDependencyResolverTests(void);
void ModInstallerTests(void);
void ModContentKindTests(void);

int main(void) {
    @autoreleasepool {
        ModIndexTests();
        ModProfileInfoTests();
        ModVersionSelectorTests();
        ModFolderTests();
        ModDependencyResolverTests();
        ModInstallerTests();
        ModContentKindTests();
    }
    if (gModTestFailures > 0) {
        fprintf(stderr, "%d assertion(s) failed\n", gModTestFailures);
        return 1;
    }
    printf("All mod tests passed\n");
    return 0;
}
