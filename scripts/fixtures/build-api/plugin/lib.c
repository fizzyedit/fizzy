// Weak: both fixture packages link this file into one executable.
__attribute__((weak)) int fixture_answer(void) {
    return 42;
}
