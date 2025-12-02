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
// Uses heuristic: pointer values when encoded as double are very large
// or have specific patterns that don't look like normal numbers
void eigen_print_val(double val) {
    PointerDoubleUnion u;
    u.d = val;
    // Check if this looks like an encoded pointer
    // Pointers on x86_64 are typically in ranges like 0x7f... or 0x5...
    // When interpreted as double, these create very specific patterns
    // A simple heuristic: if the value when viewed as i64 is in pointer range
    // and the double representation is unusual (NaN, Inf, or very large)
    int64_t as_int = u.i;

    // Check if it might be a heap pointer (typical ranges)
    if ((as_int > 0x100000000LL && as_int < 0x800000000000LL) ||
        (as_int > 0x7f0000000000LL && as_int < 0x800000000000LL)) {
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
