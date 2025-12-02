/**
 * EigenScript Runtime Library - EigenValue Header
 * 
 * Provides geometric state tracking for compiled EigenScript programs.
 */

#ifndef EIGENVALUE_H
#define EIGENVALUE_H

#include <stdint.h>
#include <stdbool.h>

#define MAX_HISTORY 100  // Maximum history for stability calculation
#define CONVERGENCE_THRESHOLD 1e-6
#define DIVERGENCE_THRESHOLD 1e3
#define OSCILLATION_CYCLES 3

/**
 * EigenValue structure: tracks value + geometric properties
 */
typedef struct {
    double value;          // Current value
    double gradient;       // Rate of change (derivative)
    double stability;      // Stability metric
    int64_t iteration;     // Number of updates
    
    // History for calculating geometric properties
    double history[MAX_HISTORY];
    int history_size;
    int history_index;
    
    double prev_value;     // Previous value for gradient calculation
    double prev_gradient;  // Previous gradient for acceleration
} EigenValue;

/**
 * Runtime API Functions
 */

// Create a new EigenValue with initial value (heap allocation)
EigenValue* eigen_create(double initial_value);

// Initialize an already-allocated EigenValue (for stack allocation)
void eigen_init(EigenValue* ev, double initial_value);

// Update an EigenValue with a new value
void eigen_update(EigenValue* ev, double new_value);

// Get current value
double eigen_get_value(EigenValue* ev);

// Get gradient (why - direction of change)
double eigen_get_gradient(EigenValue* ev);

// Get stability metric (how - quality/stability)
double eigen_get_stability(EigenValue* ev);

// Get iteration count (when)
int64_t eigen_get_iteration(EigenValue* ev);

// Predicates
bool eigen_check_converged(EigenValue* ev);
bool eigen_check_diverging(EigenValue* ev);
bool eigen_check_oscillating(EigenValue* ev);
bool eigen_check_stable(EigenValue* ev);
bool eigen_check_improving(EigenValue* ev);

// Cleanup
void eigen_destroy(EigenValue* ev);

/**
 * EigenList structure: dynamic array of doubles
 */
typedef struct {
    double* data;
    int64_t length;
    int64_t capacity;
} EigenList;

/**
 * List API Functions
 */

// Create a new EigenList with given capacity
EigenList* eigen_list_create(int64_t length);

// Get element at index
double eigen_list_get(EigenList* list, int64_t index);

// Set element at index
void eigen_list_set(EigenList* list, int64_t index, double value);

// Get list length
int64_t eigen_list_length(EigenList* list);

// Append element to end of list
void eigen_list_append(EigenList* list, double value);

// Cleanup
void eigen_list_destroy(EigenList* list);

/**
 * String API Functions
 *
 * These enable self-hosting by providing native string manipulation
 * without Python/NumPy dependency. Essential for writing lexer/parser
 * in EigenScript itself.
 */

// EigenString structure: length-prefixed string with capacity for growth
typedef struct {
    char* data;         // UTF-8 string data (null-terminated for C compat)
    int64_t length;     // String length in bytes (not including null terminator)
    int64_t capacity;   // Allocated capacity
} EigenString;

// Create a new EigenString from C string (copies the data)
EigenString* eigen_string_create(const char* str);

// Create an empty EigenString with given capacity
EigenString* eigen_string_create_empty(int64_t capacity);

// Destroy an EigenString and free memory
void eigen_string_destroy(EigenString* str);

// Get string length
int64_t eigen_string_length(EigenString* str);

// Get character code at index (returns -1 if out of bounds)
int64_t eigen_char_at(EigenString* str, int64_t index);

// Extract substring (returns new EigenString, caller must free)
EigenString* eigen_substring(EigenString* str, int64_t start, int64_t length);

// Concatenate two strings (returns new EigenString, caller must free)
EigenString* eigen_string_concat(EigenString* a, EigenString* b);

// Append a character to string (modifies in place, may reallocate)
void eigen_string_append_char(EigenString* str, int64_t char_code);

// Compare two strings (returns 0 if equal, <0 if a<b, >0 if a>b)
int64_t eigen_string_compare(EigenString* a, EigenString* b);

// Check if strings are equal (returns 1 if equal, 0 otherwise)
int64_t eigen_string_equals(EigenString* a, EigenString* b);

// Character classification functions (for lexer)
int64_t eigen_char_is_digit(int64_t c);      // '0'-'9'
int64_t eigen_char_is_alpha(int64_t c);      // 'a'-'z', 'A'-'Z'
int64_t eigen_char_is_alnum(int64_t c);      // digit or alpha
int64_t eigen_char_is_whitespace(int64_t c); // space, tab, newline, etc.
int64_t eigen_char_is_newline(int64_t c);    // '\n' or '\r'

// Convert character code to single-char string
EigenString* eigen_char_to_string(int64_t char_code);

// Convert number to string
EigenString* eigen_number_to_string(double value);

// Parse string to number (returns NaN on failure)
double eigen_string_to_number(EigenString* str);

// Find substring (returns index or -1 if not found)
int64_t eigen_string_find(EigenString* haystack, EigenString* needle, int64_t start);

// Get raw C string pointer (for interop - do not free!)
const char* eigen_string_cstr(EigenString* str);

#endif // EIGENVALUE_H
