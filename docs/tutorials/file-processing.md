# Tutorial 4: File Processing

**⏱️ Time: 60 minutes** | **Difficulty: Intermediate**

Learn to work with files and JSON data in EigenScript.

## Topics Covered

- Reading and writing files
- JSON parsing
- CSV processing
- Data pipelines

## Reading Files

```eigenscript
handle is file_open of ["data.txt", "r"]
content is file_read of handle
file_close of handle
print of content
```

## Writing Files

```eigenscript
handle is file_open of ["output.txt", "w"]
file_write of [handle, "Hello, file!"]
file_close of handle
```

## JSON Operations

```eigenscript
# Parse JSON
json_str is '{"name": "Alice", "age": 30}'
data is json_parse of json_str

# Create JSON
person is ["name", "Bob", "age", 25]
json_out is json_stringify of person
print of json_out
```

## CSV Processing

```eigenscript
# Read CSV
handle is file_open of ["data.csv", "r"]
content is file_read of handle
file_close of handle

# Parse rows
lines is split of [content, "\n"]

define parse_row as:
    return split of [line, ","]

rows is map of [parse_row, lines]
print of rows
```

**Next:** [Tutorial 5: Self-Aware Code](self-aware-code.md) →
