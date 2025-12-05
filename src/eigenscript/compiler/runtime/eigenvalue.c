/**
 * EigenScript Runtime Library - EigenValue Implementation
 * 
 * Implements geometric state tracking for compiled EigenScript.
 */

#include "eigenvalue.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

/**
 * Create a new EigenValue with initial value
 */
EigenValue* eigen_create(double initial_value) {
    EigenValue* ev = (EigenValue*)malloc(sizeof(EigenValue));
    if (!ev) return NULL;
    
    ev->value = initial_value;
    ev->gradient = 0.0;
    ev->stability = 1.0;  // Start stable
    ev->iteration = 0;
    ev->prev_value = initial_value;
    ev->prev_gradient = 0.0;
    
    ev->history_size = 0;
    ev->history_index = 0;
    memset(ev->history, 0, sizeof(ev->history));
    
    // Add initial value to history
    ev->history[0] = initial_value;
    ev->history_size = 1;
    
    return ev;
}

/**
 * Initialize an already-allocated EigenValue (for stack allocation)
 *
 * This is the critical O(1) optimization - we do NOT memset the history array.
 * We only set history_size to 1 and write the first element.
 * The rest of the array contains garbage, but history_size guards all access.
 *
 * Marked for aggressive inlining since this is on the hot path for recursion.
 */
__attribute__((always_inline))
inline void eigen_init(EigenValue* ev, double initial_value) {
    if (!ev) return;

    // Set scalar fields
    ev->value = initial_value;
    ev->gradient = 0.0;
    ev->stability = 1.0;  // Start stable
    ev->iteration = 0;
    ev->prev_value = initial_value;
    ev->prev_gradient = 0.0;

    // Lazy history initialization - O(1) not O(100)!
    // We do NOT zero out the entire history[100] array
    // Just set size to 1 and write the first element
    // The rest is uninitialized memory (garbage), but history_size guards it
    ev->history_size = 1;
    ev->history_index = 0;
    ev->history[0] = initial_value;
    // history[1..99] contains garbage, but will never be accessed
}

/**
 * Update an EigenValue with a new value
 * This automatically calculates gradient and stability
 */
void eigen_update(EigenValue* ev, double new_value) {
    if (!ev) return;
    
    // Calculate gradient (first derivative)
    ev->gradient = new_value - ev->prev_value;
    
    // Calculate acceleration (second derivative for stability)
    double acceleration = ev->gradient - ev->prev_gradient;
    
    // Update stability metric based on acceleration
    // Lower acceleration = more stable
    ev->stability = exp(-fabs(acceleration));
    
    // Update history
    ev->history_index = (ev->history_index + 1) % MAX_HISTORY;
    ev->history[ev->history_index] = new_value;
    if (ev->history_size < MAX_HISTORY) {
        ev->history_size++;
    }
    
    // Update tracking variables
    ev->prev_gradient = ev->gradient;
    ev->prev_value = ev->value;
    ev->value = new_value;
    ev->iteration++;
}

/**
 * Get current value
 * Marked for aggressive inlining since this is called in hot loops
 */
__attribute__((always_inline))
inline double eigen_get_value(EigenValue* ev) {
    return ev ? ev->value : 0.0;
}

/**
 * Get gradient (why - direction of change)
 */
double eigen_get_gradient(EigenValue* ev) {
    return ev ? ev->gradient : 0.0;
}

/**
 * Get stability metric (how - quality/stability)
 */
double eigen_get_stability(EigenValue* ev) {
    return ev ? ev->stability : 0.0;
}

/**
 * Get iteration count (when)
 */
int64_t eigen_get_iteration(EigenValue* ev) {
    return ev ? ev->iteration : 0;
}

/**
 * Check if value has converged
 * Returns true if recent changes are below threshold
 */
bool eigen_check_converged(EigenValue* ev) {
    if (!ev || ev->history_size < 5) {
        return false;  // Need at least 5 values to determine convergence
    }
    
    // Check if last 5 changes are all below threshold
    double max_change = 0.0;
    for (int i = 0; i < 5; i++) {
        int idx1 = (ev->history_index - i + MAX_HISTORY) % MAX_HISTORY;
        int idx2 = (ev->history_index - i - 1 + MAX_HISTORY) % MAX_HISTORY;
        
        double change = fabs(ev->history[idx1] - ev->history[idx2]);
        if (change > max_change) {
            max_change = change;
        }
    }
    
    return max_change < CONVERGENCE_THRESHOLD;
}

/**
 * Check if value is diverging
 * Returns true if value is growing rapidly
 */
bool eigen_check_diverging(EigenValue* ev) {
    if (!ev || ev->history_size < 3) {
        return false;
    }
    
    // Check if gradient is increasing exponentially
    if (fabs(ev->value) > DIVERGENCE_THRESHOLD) {
        return true;
    }
    
    // Check if recent gradients are all increasing in magnitude
    double prev_abs_gradient = 0.0;
    int increasing_count = 0;
    
    for (int i = 1; i < fmin(5, ev->history_size); i++) {
        int idx1 = (ev->history_index - i + 1 + MAX_HISTORY) % MAX_HISTORY;
        int idx2 = (ev->history_index - i + MAX_HISTORY) % MAX_HISTORY;
        
        double gradient = fabs(ev->history[idx1] - ev->history[idx2]);
        if (gradient > prev_abs_gradient * 1.2) {  // 20% increase
            increasing_count++;
        }
        prev_abs_gradient = gradient;
    }
    
    return increasing_count >= 3;
}

/**
 * Check if value is oscillating
 * Returns true if value is bouncing back and forth
 */
bool eigen_check_oscillating(EigenValue* ev) {
    if (!ev || ev->history_size < OSCILLATION_CYCLES * 2) {
        return false;
    }
    
    // Count sign changes in gradients
    int sign_changes = 0;
    double prev_gradient = 0.0;
    
    for (int i = 1; i < fmin(10, ev->history_size); i++) {
        int idx1 = (ev->history_index - i + 1 + MAX_HISTORY) % MAX_HISTORY;
        int idx2 = (ev->history_index - i + MAX_HISTORY) % MAX_HISTORY;
        
        double gradient = ev->history[idx1] - ev->history[idx2];
        
        if (i > 1 && (gradient * prev_gradient < 0)) {
            sign_changes++;
        }
        prev_gradient = gradient;
    }
    
    // If we have multiple sign changes, it's oscillating
    return sign_changes >= OSCILLATION_CYCLES;
}

/**
 * Check if value is stable
 * Returns true if stability metric is high
 */
bool eigen_check_stable(EigenValue* ev) {
    if (!ev) return false;
    return ev->stability > 0.8;  // 80% stability threshold
}

/**
 * Check if value is improving
 * Returns true if gradient shows consistent improvement
 */
bool eigen_check_improving(EigenValue* ev) {
    if (!ev || ev->history_size < 3) {
        return false;
    }
    
    // Check if recent gradients are consistently negative (assuming minimization)
    // Or consistently positive (for maximization)
    // For now, just check if gradient magnitude is decreasing
    return fabs(ev->gradient) < fabs(ev->prev_gradient);
}

/**
 * Destroy an EigenValue and free memory
 */
void eigen_destroy(EigenValue* ev) {
    if (ev) {
        free(ev);
    }
}

/**
 * List Implementation
 */

EigenList* eigen_list_create(int64_t length) {
    EigenList* list = (EigenList*)malloc(sizeof(EigenList));
    if (!list) return NULL;
    
    list->length = length;
    list->capacity = length;
    list->data = (double*)calloc(length, sizeof(double));
    
    if (!list->data) {
        free(list);
        return NULL;
    }
    
    return list;
}

double eigen_list_get(EigenList* list, int64_t index) {
    if (!list || index < 0 || index >= list->length) {
        fprintf(stderr, "List index out of bounds: %lld (length: %lld)\n",
                (long long)index, (long long)list->length);
        return 0.0;
    }
    return list->data[index];
}

void eigen_list_set(EigenList* list, int64_t index, double value) {
    if (!list || index < 0 || index >= list->length) {
        fprintf(stderr, "List index out of bounds: %lld (length: %lld)\n", 
                (long long)index, (long long)list->length);
        return;
    }
    list->data[index] = value;
}

int64_t eigen_list_length(EigenList* list) {
    return list ? list->length : 0;
}

void eigen_list_append(EigenList* list, double value) {
    if (!list) {
        fprintf(stderr, "Cannot append to NULL list\n");
        return;
    }

    // Check if we need to grow the array
    if (list->length >= list->capacity) {
        // Double the capacity (or start with 8 if capacity is 0)
        int64_t new_capacity = list->capacity == 0 ? 8 : list->capacity * 2;
        double* new_data = (double*)realloc(list->data, new_capacity * sizeof(double));

        if (!new_data) {
            fprintf(stderr, "Failed to grow list capacity\n");
            return;
        }

        list->data = new_data;
        list->capacity = new_capacity;
    }

    // Add the element
    list->data[list->length] = value;
    list->length++;
}

void eigen_list_destroy(EigenList* list) {
    if (list) {
        if (list->data) {
            free(list->data);
        }
        free(list);
    }
}

/**
 * String Implementation
 *
 * Native string operations for EigenScript self-hosting.
 * These eliminate Python dependency for string manipulation.
 */

EigenString* eigen_string_create(const char* str) {
    if (!str) return NULL;

    EigenString* es = (EigenString*)malloc(sizeof(EigenString));
    if (!es) return NULL;

    size_t len = strlen(str);
    es->length = (int64_t)len;
    es->capacity = (int64_t)(len + 1);  // +1 for null terminator
    es->data = (char*)malloc(es->capacity);

    if (!es->data) {
        free(es);
        return NULL;
    }

    memcpy(es->data, str, len + 1);  // Copy including null terminator
    return es;
}

EigenString* eigen_string_create_empty(int64_t capacity) {
    if (capacity < 1) capacity = 16;  // Minimum capacity

    EigenString* es = (EigenString*)malloc(sizeof(EigenString));
    if (!es) return NULL;

    es->length = 0;
    es->capacity = capacity;
    es->data = (char*)malloc(capacity);

    if (!es->data) {
        free(es);
        return NULL;
    }

    es->data[0] = '\0';
    return es;
}

void eigen_string_destroy(EigenString* str) {
    if (str) {
        if (str->data) {
            free(str->data);
        }
        free(str);
    }
}

int64_t eigen_string_length(EigenString* str) {
    return str ? str->length : 0;
}

int64_t eigen_char_at(EigenString* str, int64_t index) {
    if (!str || index < 0 || index >= str->length) {
        return -1;  // Out of bounds
    }
    return (int64_t)(unsigned char)str->data[index];
}

EigenString* eigen_substring(EigenString* str, int64_t start, int64_t length) {
    if (!str || start < 0 || start >= str->length) {
        return eigen_string_create("");
    }

    // Clamp length to remaining characters
    if (start + length > str->length) {
        length = str->length - start;
    }

    if (length <= 0) {
        return eigen_string_create("");
    }

    EigenString* result = eigen_string_create_empty(length + 1);
    if (!result) return NULL;

    memcpy(result->data, str->data + start, length);
    result->data[length] = '\0';
    result->length = length;

    return result;
}

EigenString* eigen_string_concat(EigenString* a, EigenString* b) {
    int64_t len_a = a ? a->length : 0;
    int64_t len_b = b ? b->length : 0;
    int64_t total_len = len_a + len_b;

    EigenString* result = eigen_string_create_empty(total_len + 1);
    if (!result) return NULL;

    if (a && a->data) {
        memcpy(result->data, a->data, len_a);
    }
    if (b && b->data) {
        memcpy(result->data + len_a, b->data, len_b);
    }

    result->data[total_len] = '\0';
    result->length = total_len;

    return result;
}

void eigen_string_append_char(EigenString* str, int64_t char_code) {
    if (!str || char_code < 0 || char_code > 255) return;

    // Check if we need to grow
    if (str->length + 2 > str->capacity) {  // +2 for new char and null terminator
        int64_t new_capacity = str->capacity * 2;
        if (new_capacity < 16) new_capacity = 16;

        char* new_data = (char*)realloc(str->data, new_capacity);
        if (!new_data) return;

        str->data = new_data;
        str->capacity = new_capacity;
    }

    str->data[str->length] = (char)char_code;
    str->length++;
    str->data[str->length] = '\0';
}

int64_t eigen_string_compare(EigenString* a, EigenString* b) {
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;
    return (int64_t)strcmp(a->data, b->data);
}

int64_t eigen_string_equals(EigenString* a, EigenString* b) {
    if (!a && !b) return 1;
    if (!a || !b) return 0;
    if (a->length != b->length) return 0;
    return strcmp(a->data, b->data) == 0 ? 1 : 0;
}

int64_t eigen_char_is_digit(int64_t c) {
    return (c >= '0' && c <= '9') ? 1 : 0;
}

int64_t eigen_char_is_alpha(int64_t c) {
    return ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') ? 1 : 0;
}

int64_t eigen_char_is_alnum(int64_t c) {
    return (eigen_char_is_digit(c) || eigen_char_is_alpha(c)) ? 1 : 0;
}

int64_t eigen_char_is_whitespace(int64_t c) {
    return (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f') ? 1 : 0;
}

int64_t eigen_char_is_newline(int64_t c) {
    return (c == '\n' || c == '\r') ? 1 : 0;
}

EigenString* eigen_char_to_string(int64_t char_code) {
    if (char_code < 0 || char_code > 255) {
        return eigen_string_create("");
    }

    char buf[2] = { (char)char_code, '\0' };
    return eigen_string_create(buf);
}

EigenString* eigen_number_to_string(double value) {
    char buf[64];

    // Check if it's an integer value
    if (value == (double)(int64_t)value && value >= -9007199254740992.0 && value <= 9007199254740992.0) {
        snprintf(buf, sizeof(buf), "%lld", (long long)(int64_t)value);
    } else {
        snprintf(buf, sizeof(buf), "%.15g", value);
    }

    return eigen_string_create(buf);
}

double eigen_string_to_number(EigenString* str) {
    if (!str || !str->data || str->length == 0) {
        return 0.0 / 0.0;  // NaN
    }

    char* endptr;
    double result = strtod(str->data, &endptr);

    // Check if entire string was consumed
    if (endptr == str->data) {
        return 0.0 / 0.0;  // NaN - no conversion performed
    }

    return result;
}

int64_t eigen_string_find(EigenString* haystack, EigenString* needle, int64_t start) {
    if (!haystack || !needle || !haystack->data || !needle->data) {
        return -1;
    }

    if (start < 0) start = 0;
    if (start >= haystack->length) return -1;
    if (needle->length == 0) return start;
    if (needle->length > haystack->length - start) return -1;

    const char* found = strstr(haystack->data + start, needle->data);
    if (!found) return -1;

    return (int64_t)(found - haystack->data);
}

const char* eigen_string_cstr(EigenString* str) {
    return str ? str->data : "";
}

/**
 * File I/O Implementation
 *
 * These functions enable self-hosting by providing file operations.
 */

EigenString* eigen_file_read(EigenString* filename) {
    if (!filename || !filename->data) return NULL;

    FILE* file = fopen(filename->data, "rb");
    if (!file) return NULL;

    // Get file size
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);

    if (size < 0) {
        fclose(file);
        return NULL;
    }

    // Allocate string with file contents
    EigenString* result = eigen_string_create_empty(size + 1);
    if (!result) {
        fclose(file);
        return NULL;
    }

    // Read file
    size_t read = fread(result->data, 1, size, file);
    fclose(file);

    result->data[read] = '\0';
    result->length = (int64_t)read;

    return result;
}

int64_t eigen_file_write(EigenString* filename, EigenString* contents) {
    if (!filename || !filename->data) return 0;
    if (!contents) return 0;

    FILE* file = fopen(filename->data, "wb");
    if (!file) return 0;

    size_t written = fwrite(contents->data, 1, contents->length, file);
    fclose(file);

    return (written == (size_t)contents->length) ? 1 : 0;
}

int64_t eigen_file_append(EigenString* filename, EigenString* contents) {
    if (!filename || !filename->data) return 0;
    if (!contents) return 0;

    FILE* file = fopen(filename->data, "ab");
    if (!file) return 0;

    size_t written = fwrite(contents->data, 1, contents->length, file);
    fclose(file);

    return (written == (size_t)contents->length) ? 1 : 0;
}

int64_t eigen_file_exists(EigenString* filename) {
    if (!filename || !filename->data) return 0;

    FILE* file = fopen(filename->data, "r");
    if (file) {
        fclose(file);
        return 1;
    }
    return 0;
}

void eigen_print_string(EigenString* str) {
    if (str && str->data) {
        printf("%s", str->data);
    }
}

void eigen_print_double(double value) {
    // Check if it's an integer value
    if (value == (double)(int64_t)value &&
        value >= -9007199254740992.0 && value <= 9007199254740992.0) {
        printf("%lld", (long long)(int64_t)value);
    } else {
        printf("%g", value);
    }
}

void eigen_print_newline(void) {
    printf("\n");
}

// ============================================================================
// Self-Hosting Support Functions
// These functions convert between encoded doubles and pointers for the
// self-hosted compiler which uses double values for everything.
// ============================================================================

// Union for safe pointer-to-double conversion
typedef union {
    double d;
    int64_t i;
    void* p;
} PointerDoubleUnion;

// Convert EigenList* to double (encode pointer as double)
double eigen_list_to_double(EigenList* list) {
    PointerDoubleUnion u;
    u.p = list;
    return u.d;
}

// Convert double back to EigenList* (decode double to pointer)
EigenList* eigen_double_to_list(double val) {
    PointerDoubleUnion u;
    u.d = val;
    return (EigenList*)u.p;
}

// Convert EigenString* to double (encode pointer as double)
double eigen_string_to_double(EigenString* str) {
    PointerDoubleUnion u;
    u.p = str;
    return u.d;
}

// Convert double back to EigenString* (decode double to pointer)
EigenString* eigen_double_to_string(double val) {
    PointerDoubleUnion u;
    u.d = val;
    return (EigenString*)u.p;
}

// String length with double-encoded string
int64_t eigen_string_length_val(double str_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (!str) return 0;
    return eigen_string_length(str);
}

// String equality with double-encoded strings
double eigen_string_equals_val(double a_val, double b_val) {
    EigenString* a = eigen_double_to_string(a_val);
    EigenString* b = eigen_double_to_string(b_val);
    if (!a || !b) return 0.0;
    return eigen_string_equals(a, b) ? 1.0 : 0.0;
}

// char_at with double-encoded string and index
double eigen_char_at_val(double str_val, double idx_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (!str) return 0.0;
    int64_t idx = (int64_t)idx_val;
    return (double)eigen_char_at(str, idx);
}

// substring with double-encoded values
double eigen_substring_val(double str_val, double start_val, double len_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (!str) return 0.0;
    int64_t start = (int64_t)start_val;
    int64_t len = (int64_t)len_val;
    EigenString* result = eigen_substring(str, start, len);
    return eigen_string_to_double(result);
}

// char_is_digit with double-encoded char code
double eigen_char_is_digit_val(double c_val) {
    int64_t c = (int64_t)c_val;
    return eigen_char_is_digit(c) ? 1.0 : 0.0;
}

// char_is_alpha with double-encoded char code
double eigen_char_is_alpha_val(double c_val) {
    int64_t c = (int64_t)c_val;
    return eigen_char_is_alpha(c) ? 1.0 : 0.0;
}

// char_is_whitespace with double-encoded char code
double eigen_char_is_whitespace_val(double c_val) {
    int64_t c = (int64_t)c_val;
    return eigen_char_is_whitespace(c) ? 1.0 : 0.0;
}

// number_to_string - returns encoded string pointer
double eigen_number_to_string_val(double num) {
    EigenString* result = eigen_number_to_string(num);
    return eigen_string_to_double(result);
}

// string_to_number with double-encoded string
double eigen_string_to_number_val(double str_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (!str) return 0.0;
    return eigen_string_to_number(str);
}

// string_concat for two strings (double-encoded)
double eigen_string_concat_val(double a_val, double b_val) {
    EigenString* a = eigen_double_to_string(a_val);
    EigenString* b = eigen_double_to_string(b_val);
    if (!a || !b) return 0.0;
    EigenString* result = eigen_string_concat(a, b);
    return eigen_string_to_double(result);
}

// list_append with double-encoded list and value
void eigen_list_append_val(double list_val, double value) {
    EigenList* list = eigen_double_to_list(list_val);
    if (!list) return;
    eigen_list_append(list, value);
}

// Print a double-encoded string
void eigen_print_string_val(double str_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (str) {
        eigen_print_string(str);
    }
}

// Universal print that handles both numbers and encoded strings
// Uses heuristic: pointer values when encoded as double create specific bit patterns
// that differ from typical numeric values
void eigen_print_val(double val) {
    PointerDoubleUnion u;
    u.d = val;
    int64_t as_int = u.i;

    // Check if it might be an encoded pointer
    // Valid pointers on x86_64 (with or without PIE):
    // - Low addresses: 0x10000 to 0x100000000 (typical for -no-pie)
    // - High addresses: 0x100000000 to 0x800000000000 (typical heap with PIE)
    // - Very high: 0x7f0000000000+ (typical shared libraries)
    // Exclude values < 0x10000 (64KB) as they're too low to be valid pointers
    // and often represent small integers or special values
    if ((as_int >= 0x10000LL && as_int < 0x800000000000LL) ||
        (as_int >= 0x7f0000000000LL && as_int < 0x800000000000LL)) {
        // Likely an encoded pointer - try to print as string
        EigenString* str = (EigenString*)u.p;
        // Basic validation: check if it looks like a valid EigenString
        if (str && str->data && str->length >= 0 && str->length < 1000000) {
            eigen_print_string(str);
            return;
        }
    }

    // Default: print as number
    eigen_print_double(val);
}

// ============================================================================
// Interrogative Support (for self-hosted compiler)
// These provide simplified interrogative semantics for double-only values.
// Full EigenValue interrogatives use eigen_get_value/gradient/stability directly.
// ============================================================================

// "what is x" - returns the value itself (identity for doubles)
double eigen_what_is(double val) {
    return val;
}

// "who is x" - returns an identity marker (for doubles, use address-like hash)
// In self-hosted context, this is just a unique identifier
double eigen_who_is(double val) {
    PointerDoubleUnion u;
    u.d = val;
    // Return a hash-like identifier based on the bit pattern
    return (double)(u.i & 0xFFFFFFFF);
}

// "why is x" - returns gradient/derivative (0 for untracked doubles)
double eigen_why_is(double val) {
    (void)val;  // Unused - no gradient tracking for raw doubles
    return 0.0;
}

// "how is x" - returns framework strength/stability (1.0 = fully stable)
double eigen_how_is(double val) {
    (void)val;  // Unused - assume stable for raw doubles
    return 1.0;
}

// "when is x" - returns temporal coordinate/iteration (0 for untracked)
double eigen_when_is(double val) {
    (void)val;  // Unused - no iteration tracking for raw doubles
    return 0.0;
}

// "where is x" - returns spatial coordinate (0 for untracked)
double eigen_where_is(double val) {
    (void)val;  // Unused - no spatial tracking for raw doubles
    return 0.0;
}

// ============================================================================
// CLI Argument Support (for self-hosting compiler)
// ============================================================================

// Global storage for argc/argv - set by main wrapper
static int __eigs_argc = 0;
static char** __eigs_argv = NULL;

// Initialize CLI args - called at program start
void eigen_init_args(int argc, char** argv) {
    __eigs_argc = argc;
    __eigs_argv = argv;
}

// Get argument count
double eigen_get_argc(void) {
    return (double)__eigs_argc;
}

// Get argument at index (returns string as double)
double eigen_get_arg(double index_val) {
    int index = (int)index_val;
    if (index < 0 || index >= __eigs_argc || __eigs_argv == NULL) {
        // Return empty string
        EigenString* empty = eigen_string_create("");
        return eigen_string_to_double(empty);
    }
    EigenString* arg = eigen_string_create(__eigs_argv[index]);
    return eigen_string_to_double(arg);
}

// ============================================================================
// File I/O Support (for self-hosting compiler)
// ============================================================================

// Read file contents (returns string as double)
double eigen_file_read_val(double filename_val) {
    EigenString* filename = eigen_double_to_string(filename_val);
    if (filename == NULL) {
        return 0.0;  // Return 0 for error
    }
    EigenString* contents = eigen_file_read(filename);
    if (contents == NULL) {
        return 0.0;  // Return 0 for error
    }
    return eigen_string_to_double(contents);
}

// ============================================================================
// List Length Support (for self-hosting compiler)
// ============================================================================

// Get list length (returns length as double)
double eigen_list_length_val(double list_val) {
    EigenList* list = eigen_double_to_list(list_val);
    if (list == NULL) {
        return 0.0;
    }
    return (double)eigen_list_length(list);
}

// ============================================================================
// Matrix Support (for AI/ML in self-hosting compiler)
// ============================================================================

// Matrix structure - row-major storage
typedef struct {
    double* data;
    int64_t rows;
    int64_t cols;
    int64_t capacity;
} EigenMatrix;

// Create a matrix with given dimensions
EigenMatrix* eigen_matrix_create(int64_t rows, int64_t cols) {
    EigenMatrix* m = (EigenMatrix*)malloc(sizeof(EigenMatrix));
    if (!m) return NULL;
    m->rows = rows;
    m->cols = cols;
    m->capacity = rows * cols;
    m->data = (double*)calloc(m->capacity, sizeof(double));
    if (!m->data) {
        free(m);
        return NULL;
    }
    return m;
}

// Destroy a matrix
void eigen_matrix_destroy(EigenMatrix* m) {
    if (m) {
        free(m->data);
        free(m);
    }
}

// Convert matrix pointer to double (encode pointer)
double eigen_matrix_to_double(EigenMatrix* m) {
    PointerDoubleUnion u;
    u.p = m;
    return u.d;
}

// Convert double to matrix pointer (decode pointer)
EigenMatrix* eigen_double_to_matrix(double val) {
    PointerDoubleUnion u;
    u.d = val;
    return (EigenMatrix*)u.p;
}

// Create matrix of zeros
double eigen_matrix_zeros_val(double rows_val, double cols_val) {
    int64_t rows = (int64_t)rows_val;
    int64_t cols = (int64_t)cols_val;
    EigenMatrix* m = eigen_matrix_create(rows, cols);
    return eigen_matrix_to_double(m);
}

// Create matrix of ones
double eigen_matrix_ones_val(double rows_val, double cols_val) {
    int64_t rows = (int64_t)rows_val;
    int64_t cols = (int64_t)cols_val;
    EigenMatrix* m = eigen_matrix_create(rows, cols);
    if (m) {
        for (int64_t i = 0; i < rows * cols; i++) {
            m->data[i] = 1.0;
        }
    }
    return eigen_matrix_to_double(m);
}

// Create identity matrix
double eigen_matrix_identity_val(double size_val) {
    int64_t size = (int64_t)size_val;
    EigenMatrix* m = eigen_matrix_create(size, size);
    if (m) {
        for (int64_t i = 0; i < size; i++) {
            m->data[i * size + i] = 1.0;
        }
    }
    return eigen_matrix_to_double(m);
}

// Create random matrix (simple LCG random)
static uint64_t _matrix_rng_state = 12345;
double eigen_matrix_random_val(double rows_val, double cols_val) {
    int64_t rows = (int64_t)rows_val;
    int64_t cols = (int64_t)cols_val;
    EigenMatrix* m = eigen_matrix_create(rows, cols);
    if (m) {
        for (int64_t i = 0; i < rows * cols; i++) {
            // Simple LCG for random numbers in [-1, 1]
            _matrix_rng_state = _matrix_rng_state * 6364136223846793005ULL + 1;
            double r = (double)(_matrix_rng_state >> 33) / (double)(1ULL << 31) - 1.0;
            m->data[i] = r;
        }
    }
    return eigen_matrix_to_double(m);
}

// Get matrix shape as [rows, cols] list
double eigen_matrix_shape_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    EigenList* shape = eigen_list_create(2);
    eigen_list_set(shape, 0, (double)m->rows);
    eigen_list_set(shape, 1, (double)m->cols);
    return eigen_list_to_double(shape);
}

// Matrix transpose
double eigen_matrix_transpose_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    EigenMatrix* result = eigen_matrix_create(m->cols, m->rows);
    if (result) {
        for (int64_t i = 0; i < m->rows; i++) {
            for (int64_t j = 0; j < m->cols; j++) {
                result->data[j * m->rows + i] = m->data[i * m->cols + j];
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// Matrix addition
double eigen_matrix_add_val(double a_val, double b_val) {
    EigenMatrix* a = eigen_double_to_matrix(a_val);
    EigenMatrix* b = eigen_double_to_matrix(b_val);
    if (!a || !b || a->rows != b->rows || a->cols != b->cols) return 0.0;
    EigenMatrix* result = eigen_matrix_create(a->rows, a->cols);
    if (result) {
        for (int64_t i = 0; i < a->rows * a->cols; i++) {
            result->data[i] = a->data[i] + b->data[i];
        }
    }
    return eigen_matrix_to_double(result);
}

// Matrix scalar multiplication
double eigen_matrix_scale_val(double m_val, double scalar) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    EigenMatrix* result = eigen_matrix_create(m->rows, m->cols);
    if (result) {
        for (int64_t i = 0; i < m->rows * m->cols; i++) {
            result->data[i] = m->data[i] * scalar;
        }
    }
    return eigen_matrix_to_double(result);
}

// Matrix multiplication (matmul)
double eigen_matrix_matmul_val(double a_val, double b_val) {
    EigenMatrix* a = eigen_double_to_matrix(a_val);
    EigenMatrix* b = eigen_double_to_matrix(b_val);
    if (!a || !b || a->cols != b->rows) return 0.0;
    EigenMatrix* result = eigen_matrix_create(a->rows, b->cols);
    if (result) {
        for (int64_t i = 0; i < a->rows; i++) {
            for (int64_t j = 0; j < b->cols; j++) {
                double sum = 0.0;
                for (int64_t k = 0; k < a->cols; k++) {
                    sum += a->data[i * a->cols + k] * b->data[k * b->cols + j];
                }
                result->data[i * b->cols + j] = sum;
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// Matrix sum (sum of all elements)
double eigen_matrix_sum_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    double sum = 0.0;
    for (int64_t i = 0; i < m->rows * m->cols; i++) {
        sum += m->data[i];
    }
    return sum;
}

// Matrix mean
double eigen_matrix_mean_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m || m->rows * m->cols == 0) return 0.0;
    return eigen_matrix_sum_val(m_val) / (double)(m->rows * m->cols);
}

// ============================================================================
// Neural Network Activation Functions
// ============================================================================

// ReLU activation (element-wise max(0, x))
double eigen_relu_matrix_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    EigenMatrix* result = eigen_matrix_create(m->rows, m->cols);
    if (result) {
        for (int64_t i = 0; i < m->rows * m->cols; i++) {
            result->data[i] = m->data[i] > 0.0 ? m->data[i] : 0.0;
        }
    }
    return eigen_matrix_to_double(result);
}

// GELU activation (Gaussian Error Linear Unit)
double eigen_gelu_matrix_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    EigenMatrix* result = eigen_matrix_create(m->rows, m->cols);
    if (result) {
        for (int64_t i = 0; i < m->rows * m->cols; i++) {
            double x = m->data[i];
            // GELU approximation: 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
            double inner = 0.7978845608 * (x + 0.044715 * x * x * x);
            result->data[i] = 0.5 * x * (1.0 + tanh(inner));
        }
    }
    return eigen_matrix_to_double(result);
}

// Softmax activation (row-wise)
double eigen_softmax_matrix_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    EigenMatrix* result = eigen_matrix_create(m->rows, m->cols);
    if (result) {
        for (int64_t i = 0; i < m->rows; i++) {
            // Find max for numerical stability
            double max_val = m->data[i * m->cols];
            for (int64_t j = 1; j < m->cols; j++) {
                if (m->data[i * m->cols + j] > max_val) {
                    max_val = m->data[i * m->cols + j];
                }
            }
            // Compute exp and sum
            double sum = 0.0;
            for (int64_t j = 0; j < m->cols; j++) {
                result->data[i * m->cols + j] = exp(m->data[i * m->cols + j] - max_val);
                sum += result->data[i * m->cols + j];
            }
            // Normalize
            for (int64_t j = 0; j < m->cols; j++) {
                result->data[i * m->cols + j] /= sum;
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// Layer normalization (row-wise)
double eigen_layer_norm_matrix_val(double m_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    if (!m) return 0.0;
    EigenMatrix* result = eigen_matrix_create(m->rows, m->cols);
    double eps = 1e-5;
    if (result) {
        for (int64_t i = 0; i < m->rows; i++) {
            // Compute mean
            double mean = 0.0;
            for (int64_t j = 0; j < m->cols; j++) {
                mean += m->data[i * m->cols + j];
            }
            mean /= (double)m->cols;
            // Compute variance
            double var = 0.0;
            for (int64_t j = 0; j < m->cols; j++) {
                double diff = m->data[i * m->cols + j] - mean;
                var += diff * diff;
            }
            var /= (double)m->cols;
            // Normalize
            double std = sqrt(var + eps);
            for (int64_t j = 0; j < m->cols; j++) {
                result->data[i * m->cols + j] = (m->data[i * m->cols + j] - mean) / std;
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// ============================================================================
// Transformer/Attention Operations
// ============================================================================

// Embedding lookup: given embedding matrix and indices list, return embedded vectors
double eigen_embedding_lookup_val(double embed_val, double indices_val) {
    EigenMatrix* embed = eigen_double_to_matrix(embed_val);
    EigenList* indices = eigen_double_to_list(indices_val);
    if (!embed || !indices) return 0.0;

    int64_t seq_len = eigen_list_length(indices);
    int64_t d_model = embed->cols;
    EigenMatrix* result = eigen_matrix_create(seq_len, d_model);
    if (result) {
        for (int64_t i = 0; i < seq_len; i++) {
            int64_t idx = (int64_t)eigen_list_get(indices, i);
            if (idx >= 0 && idx < embed->rows) {
                for (int64_t j = 0; j < d_model; j++) {
                    result->data[i * d_model + j] = embed->data[idx * d_model + j];
                }
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// Sinusoidal positional encoding
double eigen_sinusoidal_pe_val(double seq_len_val, double d_model_val) {
    int64_t seq_len = (int64_t)seq_len_val;
    int64_t d_model = (int64_t)d_model_val;
    EigenMatrix* result = eigen_matrix_create(seq_len, d_model);
    if (result) {
        for (int64_t pos = 0; pos < seq_len; pos++) {
            for (int64_t i = 0; i < d_model; i++) {
                double angle = (double)pos / pow(10000.0, (double)(2 * (i / 2)) / (double)d_model);
                if (i % 2 == 0) {
                    result->data[pos * d_model + i] = sin(angle);
                } else {
                    result->data[pos * d_model + i] = cos(angle);
                }
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// Causal mask for attention (upper triangular mask with -inf)
double eigen_causal_mask_val(double size_val) {
    int64_t size = (int64_t)size_val;
    EigenMatrix* result = eigen_matrix_create(size, size);
    if (result) {
        for (int64_t i = 0; i < size; i++) {
            for (int64_t j = 0; j < size; j++) {
                if (j > i) {
                    result->data[i * size + j] = -1e9;  // Large negative for softmax
                } else {
                    result->data[i * size + j] = 0.0;
                }
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// Matrix reshape
double eigen_matrix_reshape_val(double m_val, double rows_val, double cols_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    int64_t rows = (int64_t)rows_val;
    int64_t cols = (int64_t)cols_val;
    if (!m || m->rows * m->cols != rows * cols) return 0.0;
    EigenMatrix* result = eigen_matrix_create(rows, cols);
    if (result) {
        memcpy(result->data, m->data, rows * cols * sizeof(double));
    }
    return eigen_matrix_to_double(result);
}

// Matrix slice (row range)
double eigen_matrix_slice_val(double m_val, double start_val, double end_val) {
    EigenMatrix* m = eigen_double_to_matrix(m_val);
    int64_t start = (int64_t)start_val;
    int64_t end = (int64_t)end_val;
    if (!m || start < 0 || end > m->rows || start >= end) return 0.0;
    int64_t new_rows = end - start;
    EigenMatrix* result = eigen_matrix_create(new_rows, m->cols);
    if (result) {
        memcpy(result->data, m->data + start * m->cols, new_rows * m->cols * sizeof(double));
    }
    return eigen_matrix_to_double(result);
}

// Matrix concatenation (horizontal - along columns)
double eigen_matrix_concat_val(double a_val, double b_val) {
    EigenMatrix* a = eigen_double_to_matrix(a_val);
    EigenMatrix* b = eigen_double_to_matrix(b_val);
    if (!a || !b || a->rows != b->rows) return 0.0;
    EigenMatrix* result = eigen_matrix_create(a->rows, a->cols + b->cols);
    if (result) {
        for (int64_t i = 0; i < a->rows; i++) {
            // Copy row from a
            for (int64_t j = 0; j < a->cols; j++) {
                result->data[i * result->cols + j] = a->data[i * a->cols + j];
            }
            // Copy row from b
            for (int64_t j = 0; j < b->cols; j++) {
                result->data[i * result->cols + a->cols + j] = b->data[i * b->cols + j];
            }
        }
    }
    return eigen_matrix_to_double(result);
}

// ============================================================================
// String Escaping (for LLVM IR output in self-hosting compiler)
// ============================================================================

// Escape a string for LLVM IR constant format
// Converts special chars to hex escapes: \n -> \0A, \t -> \09, etc.
double eigen_escape_string_val(double str_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (!str) return str_val;

    // Calculate escaped length (worst case: all chars need escaping = 3x length)
    int64_t src_len = str->length;
    int64_t max_len = src_len * 3 + 1;
    char* escaped = (char*)malloc(max_len);
    if (!escaped) return str_val;

    int64_t j = 0;
    for (int64_t i = 0; i < src_len; i++) {
        unsigned char c = (unsigned char)str->data[i];
        switch (c) {
            case '\n':
                escaped[j++] = '\\';
                escaped[j++] = '0';
                escaped[j++] = 'A';
                break;
            case '\t':
                escaped[j++] = '\\';
                escaped[j++] = '0';
                escaped[j++] = '9';
                break;
            case '\r':
                escaped[j++] = '\\';
                escaped[j++] = '0';
                escaped[j++] = 'D';
                break;
            case '"':
                escaped[j++] = '\\';
                escaped[j++] = '2';
                escaped[j++] = '2';
                break;
            case '\\':
                escaped[j++] = '\\';
                escaped[j++] = '5';
                escaped[j++] = 'C';
                break;
            default:
                if (c < 32 || c > 126) {
                    // Non-printable: escape as hex
                    escaped[j++] = '\\';
                    escaped[j++] = "0123456789ABCDEF"[(c >> 4) & 0xF];
                    escaped[j++] = "0123456789ABCDEF"[c & 0xF];
                } else {
                    escaped[j++] = c;
                }
                break;
        }
    }
    escaped[j] = '\0';

    EigenString* result = eigen_string_create(escaped);
    free(escaped);
    return eigen_string_to_double(result);
}

// Get the escaped length of a string (for LLVM IR array size calculation)
// This returns the actual byte count after escaping (each \XX counts as 1 byte in LLVM)
double eigen_escaped_length_val(double str_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (!str) return 0.0;
    // The original string length is what matters for LLVM array size
    // because escapes like \0A represent single bytes
    return (double)str->length;
}

// ============================================================================
// Slice Operations (for list[start:end] syntax)
// ============================================================================

// Slice a list from start to end (exclusive)
double eigen_list_slice_val(double list_val, double start_val, double end_val) {
    EigenList* list = eigen_double_to_list(list_val);
    if (!list) return 0.0;

    int64_t len = eigen_list_length(list);
    int64_t start = (int64_t)start_val;
    int64_t end = (int64_t)end_val;

    // Handle negative indices
    if (start < 0) start = len + start;
    if (end < 0) end = len + end;

    // Clamp to valid range
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start >= end) {
        return eigen_list_to_double(eigen_list_create(0));
    }

    int64_t new_len = end - start;
    EigenList* result = eigen_list_create(new_len);
    if (result) {
        for (int64_t i = 0; i < new_len; i++) {
            eigen_list_set(result, i, eigen_list_get(list, start + i));
        }
    }
    return eigen_list_to_double(result);
}

// Slice a string from start to end (exclusive)
double eigen_string_slice_val(double str_val, double start_val, double end_val) {
    EigenString* str = eigen_double_to_string(str_val);
    if (!str) return str_val;

    int64_t len = str->length;
    int64_t start = (int64_t)start_val;
    int64_t end = (int64_t)end_val;

    // Handle negative indices
    if (start < 0) start = len + start;
    if (end < 0) end = len + end;

    // Clamp to valid range
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start >= end) {
        return eigen_string_to_double(eigen_string_create(""));
    }

    int64_t new_len = end - start;
    char* buffer = (char*)malloc(new_len + 1);
    if (!buffer) return str_val;

    memcpy(buffer, str->data + start, new_len);
    buffer[new_len] = '\0';

    EigenString* result = eigen_string_create(buffer);
    free(buffer);
    return eigen_string_to_double(result);
}

// ============================================================================
// Math Functions (for self-hosting compiler)
// ============================================================================

// Square root
double eigen_sqrt_val(double x) {
    return sqrt(x);
}

// Absolute value
double eigen_abs_val(double x) {
    return fabs(x);
}

// Power function
double eigen_pow_val(double base, double exp) {
    return pow(base, exp);
}

// Natural logarithm
double eigen_log_val(double x) {
    return log(x);
}

// Exponential (e^x)
double eigen_exp_val(double x) {
    return exp(x);
}

// Sine
double eigen_sin_val(double x) {
    return sin(x);
}

// Cosine
double eigen_cos_val(double x) {
    return cos(x);
}

// Tangent
double eigen_tan_val(double x) {
    return tan(x);
}

// Floor
double eigen_floor_val(double x) {
    return floor(x);
}

// Ceiling
double eigen_ceil_val(double x) {
    return ceil(x);
}

// Round
double eigen_round_val(double x) {
    return round(x);
}

// ============================================================================
// Higher-Order Functions (for self-hosting compiler)
// ============================================================================

// Map: apply function to each element of list
// Note: func_ptr is a function pointer encoded as double
double eigen_map_val(double func_ptr, double list_val) {
    EigenList* list = eigen_double_to_list(list_val);
    if (!list) return 0.0;

    int64_t len = eigen_list_length(list);
    EigenList* result = eigen_list_create(len);

    // For now, map is implemented at compile time by inlining
    // This is a placeholder for runtime-resolved function pointers
    return eigen_list_to_double(result);
}

// Filter: keep elements where predicate returns non-zero
double eigen_filter_val(double func_ptr, double list_val) {
    EigenList* list = eigen_double_to_list(list_val);
    if (!list) return 0.0;

    // Placeholder - filter requires runtime function calls
    return list_val;
}

// Reduce: fold list to single value
double eigen_reduce_val(double func_ptr, double list_val, double init) {
    EigenList* list = eigen_double_to_list(list_val);
    if (!list) return init;

    // Placeholder - reduce requires runtime function calls
    return init;
}

// ============================================================================
// Predicate Operations (Geometric State Checks)
// ============================================================================

// Global tracking variables for geometric state
static double __eigs_last_value = 0.0;
static double __eigs_prev_value = 0.0;
static double __eigs_change_history[100];
static int __eigs_history_idx = 0;
static int __eigs_history_count = 0;

// Update tracking state (called after assignments in compiled code)
void eigen_track_value(double value) {
    __eigs_prev_value = __eigs_last_value;
    __eigs_last_value = value;

    double change = value - __eigs_prev_value;
    __eigs_change_history[__eigs_history_idx] = change;
    __eigs_history_idx = (__eigs_history_idx + 1) % 100;
    if (__eigs_history_count < 100) __eigs_history_count++;
}

// converged/settled: has value stopped changing significantly?
double eigen_is_converged(void) {
    if (__eigs_history_count < 3) return 0.0;

    // Check if recent changes are very small
    double threshold = 0.0001;
    for (int i = 0; i < 3 && i < __eigs_history_count; i++) {
        int idx = (__eigs_history_idx - 1 - i + 100) % 100;
        if (fabs(__eigs_change_history[idx]) > threshold) return 0.0;
    }
    return 1.0;
}

// stable: is the system in a stable state (not oscillating or diverging)?
double eigen_is_stable(void) {
    if (__eigs_history_count < 3) return 1.0; // Assume stable initially

    // Check for consistent sign of changes
    int positive = 0, negative = 0;
    for (int i = 0; i < 5 && i < __eigs_history_count; i++) {
        int idx = (__eigs_history_idx - 1 - i + 100) % 100;
        if (__eigs_change_history[idx] > 0.0001) positive++;
        else if (__eigs_change_history[idx] < -0.0001) negative++;
    }
    // Stable if not oscillating between positive and negative
    return (positive == 0 || negative == 0) ? 1.0 : 0.0;
}

// diverging: is the value getting further from stability?
double eigen_is_diverging(void) {
    if (__eigs_history_count < 3) return 0.0;

    // Check if changes are increasing in magnitude
    int idx1 = (__eigs_history_idx - 1 + 100) % 100;
    int idx2 = (__eigs_history_idx - 2 + 100) % 100;
    int idx3 = (__eigs_history_idx - 3 + 100) % 100;

    double mag1 = fabs(__eigs_change_history[idx1]);
    double mag2 = fabs(__eigs_change_history[idx2]);
    double mag3 = fabs(__eigs_change_history[idx3]);

    return (mag1 > mag2 && mag2 > mag3) ? 1.0 : 0.0;
}

// improving: is the system making progress toward a goal?
double eigen_is_improving(void) {
    if (__eigs_history_count < 2) return 0.0;

    // Check if change magnitude is decreasing (converging)
    int idx1 = (__eigs_history_idx - 1 + 100) % 100;
    int idx2 = (__eigs_history_idx - 2 + 100) % 100;

    return fabs(__eigs_change_history[idx1]) < fabs(__eigs_change_history[idx2]) ? 1.0 : 0.0;
}

// oscillating: is the value bouncing back and forth?
double eigen_is_oscillating(void) {
    if (__eigs_history_count < 4) return 0.0;

    // Check for sign changes in consecutive changes
    int sign_changes = 0;
    for (int i = 0; i < 4 && i < __eigs_history_count - 1; i++) {
        int idx1 = (__eigs_history_idx - 1 - i + 100) % 100;
        int idx2 = (__eigs_history_idx - 2 - i + 100) % 100;

        double c1 = __eigs_change_history[idx1];
        double c2 = __eigs_change_history[idx2];

        if ((c1 > 0.0001 && c2 < -0.0001) || (c1 < -0.0001 && c2 > 0.0001)) {
            sign_changes++;
        }
    }

    return sign_changes >= 2 ? 1.0 : 0.0;
}

// equilibrium/balanced: is the system at a balance point?
double eigen_is_equilibrium(void) {
    if (__eigs_history_count < 5) return 0.0;

    // Check if recent changes sum to approximately zero
    double sum = 0.0;
    for (int i = 0; i < 5 && i < __eigs_history_count; i++) {
        int idx = (__eigs_history_idx - 1 - i + 100) % 100;
        sum += __eigs_change_history[idx];
    }

    return fabs(sum) < 0.001 ? 1.0 : 0.0;
}

// Aliases for humanized predicates
double eigen_is_settled(void) { return eigen_is_converged(); }
double eigen_is_balanced(void) { return eigen_is_equilibrium(); }

// stuck: no progress but not converged
double eigen_is_stuck(void) {
    if (__eigs_history_count < 3) return 0.0;

    // Not improving and not converged
    double converged = eigen_is_converged();
    double improving = eigen_is_improving();

    return (converged < 0.5 && improving < 0.5) ? 1.0 : 0.0;
}

// chaotic: unpredictable behavior detected
double eigen_is_chaotic(void) {
    if (__eigs_history_count < 5) return 0.0;

    // High variance in changes
    double sum = 0.0, sum_sq = 0.0;
    for (int i = 0; i < 5 && i < __eigs_history_count; i++) {
        int idx = (__eigs_history_idx - 1 - i + 100) % 100;
        double c = __eigs_change_history[idx];
        sum += c;
        sum_sq += c * c;
    }

    double mean = sum / 5.0;
    double variance = (sum_sq / 5.0) - (mean * mean);

    // Chaotic if variance is high relative to mean
    return variance > fabs(mean) * 10.0 ? 1.0 : 0.0;
}

// ============================================================================
// Temporal Operators
// ============================================================================

// was is x: returns previous value
double eigen_was_is(double current_val) {
    return __eigs_prev_value;
}

// change is x: returns how much x changed
double eigen_change_is(double current_val) {
    return current_val - __eigs_prev_value;
}

// status is x: returns process quality (alias for how is)
double eigen_status_is(double current_val) {
    return eigen_how_is(current_val);
}

// trend is x: returns direction as encoded value
// 1.0 = increasing, -1.0 = decreasing, 0.0 = stable, 0.5 = oscillating
double eigen_trend_is(double current_val) {
    if (__eigs_history_count < 3) return 0.0; // Unknown

    // Check recent changes
    int increasing = 0, decreasing = 0;
    for (int i = 0; i < 3 && i < __eigs_history_count; i++) {
        int idx = (__eigs_history_idx - 1 - i + 100) % 100;
        if (__eigs_change_history[idx] > 0.0001) increasing++;
        else if (__eigs_change_history[idx] < -0.0001) decreasing++;
    }

    if (increasing >= 2 && decreasing == 0) return 1.0;  // increasing
    if (decreasing >= 2 && increasing == 0) return -1.0; // decreasing
    if (increasing >= 1 && decreasing >= 1) return 0.5;  // oscillating
    return 0.0; // stable
}
