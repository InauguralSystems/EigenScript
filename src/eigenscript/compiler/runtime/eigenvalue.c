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
