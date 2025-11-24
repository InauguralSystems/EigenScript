# JSON Operations

Functions for working with JSON data in EigenScript.

---

## json_parse

Parse a JSON string into EigenScript data.

**Syntax:**
```eigenscript
data is json_parse of json_string
```

**Parameters:**
- `json_string`: String containing valid JSON

**Returns:** Parsed data (list, number, string, or bool)

**Example:**
```eigenscript
# Parse object
json_str is '{"name": "Alice", "age": 30, "active": true}'
person is json_parse of json_str
print of person

# Parse array
json_arr is '[1, 2, 3, 4, 5]'
numbers is json_parse of json_arr
print of numbers  # [1, 2, 3, 4, 5]

# Parse string
json_text is '"hello world"'
text is json_parse of json_text
print of text  # "hello world"
```

**JSON to EigenScript Mapping:**
- JSON object → List of key-value pairs
- JSON array → List
- JSON string → String
- JSON number → Number
- JSON boolean → Boolean
- JSON null → null

**Error:** Raises `JSONDecodeError` if JSON is invalid.

---

## json_stringify

Convert EigenScript data to a JSON string.

**Syntax:**
```eigenscript
json_str is json_stringify of data
```

**Parameters:**
- `data`: EigenScript value to convert

**Returns:** JSON string

**Example:**
```eigenscript
# Convert list to JSON
numbers is [1, 2, 3, 4, 5]
json_str is json_stringify of numbers
print of json_str  # "[1, 2, 3, 4, 5]"

# Convert key-value pairs to JSON object
person is ["name", "Bob", "age", 25, "active", true]
json_obj is json_stringify of person
print of json_obj
# '{"name": "Bob", "age": 25, "active": true}'

# Convert string to JSON
text is "hello"
json_text is json_stringify of text
print of json_text  # '"hello"'
```

**EigenScript to JSON Mapping:**
- List → JSON array
- String → JSON string
- Number → JSON number
- Boolean → JSON boolean
- null → JSON null

---

## Complete Examples

### Reading JSON Configuration

```eigenscript
# Read and parse JSON config file
handle is file_open of ["config.json", "r"]
json_content is file_read of handle
file_close of handle

config is json_parse of json_content
print of "Configuration loaded:"
print of config
```

### Writing JSON Data

```eigenscript
# Create data structure
users is [
    ["name", "Alice", "age", 30],
    ["name", "Bob", "age", 25],
    ["name", "Charlie", "age", 35]
]

# Convert to JSON
json_data is json_stringify of users

# Write to file
handle is file_open of ["users.json", "w"]
file_write of [handle, json_data]
file_close of handle

print of "Data saved to users.json"
```

### API Response Processing

```eigenscript
# Simulate API response
api_response is '{"status": "success", "data": [1, 2, 3], "count": 3}'

# Parse response
response is json_parse of api_response
print of "API Status:"
print of response

# Access data (conceptual - accessing nested data)
# In practice, you'd work with the parsed list structure
```

### Data Transformation Pipeline

```eigenscript
define transform_data as:
    # Read JSON
    in_handle is file_open of ["input.json", "r"]
    json_in is file_read of in_handle
    file_close of in_handle
    
    # Parse
    data is json_parse of json_in
    
    # Transform (example: double all numbers)
    define double as:
        return n * 2
    
    transformed is map of [double, data]
    
    # Convert back to JSON
    json_out is json_stringify of transformed
    
    # Write result
    out_handle is file_open of ["output.json", "w"]
    file_write of [out_handle, json_out]
    file_close of out_handle
    
    print of "Transformation complete!"

transform_data of 0
```

### Pretty Printing JSON

```eigenscript
# Note: EigenScript's json_stringify produces compact JSON
# For pretty printing, you'd need to add formatting logic

data is [
    ["name", "Alice"],
    ["age", 30],
    ["city", "Boston"]
]

json_str is json_stringify of data
print of json_str
# Output: '{"name": "Alice", "age": 30, "city": "Boston"}'
```

---

## Notes

### Nested Structures

JSON objects are represented as flat lists of key-value pairs:

```eigenscript
# This JSON:
# {"user": {"name": "Alice", "age": 30}}

# Becomes approximately:
# ["user", ["name", "Alice", "age", 30]]
```

### Array of Objects

Multiple objects in an array:

```eigenscript
# This JSON:
# [{"name": "Alice"}, {"name": "Bob"}]

# Becomes:
# [["name", "Alice"], ["name", "Bob"]]
```

### Error Handling

```eigenscript
# Invalid JSON will raise an error
bad_json is '{"name": Alice}'  # Missing quotes
# data is json_parse of bad_json  # JSONDecodeError

# Always validate JSON format before parsing
```

---

## Use Cases

1. **Configuration Files** - Store app settings in JSON
2. **Data Exchange** - Share data between programs
3. **API Integration** - Parse API responses
4. **Data Serialization** - Save complex data structures
5. **Logging** - Structured log entries

---

## Summary

JSON functions provide:

- `json_parse` - Parse JSON string to data
- `json_stringify` - Convert data to JSON string

**Total: 2 functions**

These functions enable seamless integration with JSON-based systems and APIs.

---

**Next:** [Date/Time Functions](datetime.md) →
