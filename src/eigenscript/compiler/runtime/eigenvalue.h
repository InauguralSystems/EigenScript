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

#endif // EIGENVALUE_H
