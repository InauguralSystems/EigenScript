# Week 3 Implementation Plan
**Created**: 2025-11-19  
**Status**: 🚧 IN PROGRESS  
**Goal**: Expand EigenScript standard library with practical features

---

## Executive Summary

Week 3 focuses on making EigenScript practical for real-world programs by adding essential standard library features. This plan details the implementation approach for File I/O, JSON support, Date/Time operations, and enhanced list functions.

**Estimated Duration**: 6-7 days  
**Actual Timeline**: TBD

---

## Implementation Checklist

### Phase 1: File I/O Operations (Priority: HIGH) 🔴
- [ ] Design file handle system
- [ ] Implement `file_open` function
- [ ] Implement `file_read` function
- [ ] Implement `file_write` function
- [ ] Implement `file_close` function
- [ ] Implement `file_exists` function
- [ ] Implement `list_dir` function
- [ ] Implement `file_size` function
- [ ] Implement path operations (dirname, basename, absolute_path)
- [ ] Write comprehensive tests (>80% coverage target)
- [ ] Create example programs demonstrating file I/O
- [ ] Update documentation

### Phase 2: JSON Support (Priority: HIGH) 🔴
- [ ] Implement `json_parse` function
- [ ] Implement `json_stringify` function
- [ ] Handle type conversions (EigenScript ↔ JSON)
- [ ] Support nested structures
- [ ] Write comprehensive tests (>80% coverage target)
- [ ] Create example programs with JSON
- [ ] Update documentation

### Phase 3: Date/Time Operations (Priority: MEDIUM) 🟡
- [ ] Implement `time_now` function
- [ ] Implement `time_format` function
- [ ] Implement `time_parse` function
- [ ] Implement time component extractors (year, month, day, hour, etc.)
- [ ] Support time arithmetic
- [ ] Write comprehensive tests
- [ ] Create example programs
- [ ] Update documentation

### Phase 4: Enhanced List Operations (Priority: MEDIUM) 🟡
- [ ] Implement `zip` function
- [ ] Implement `enumerate` function
- [ ] Implement `flatten` function
- [ ] Implement `reverse` function
- [ ] Write comprehensive tests
- [ ] Create example programs
- [ ] Update documentation

### Phase 5: Integration & Polish
- [ ] Run full test suite
- [ ] Verify coverage remains >78%
- [ ] Update README with new features
- [ ] Update PRODUCTION_ROADMAP.md
- [ ] Create Week 3 completion report

---

## Design Decisions

### File I/O System Design

**Approach**: Use Python's native file operations wrapped in EigenScript builtins

**Key Design Points**:
1. File handles will be LRVM vectors with metadata containing the Python file object
2. File operations will use the standard `of` operator syntax
3. Error handling will provide clear, helpful messages
4. Files will support context-manager-style automatic cleanup

**Example Usage**:
```eigenscript
# Open and read file
handle is file_open of ["data.txt", "r"]
content is file_read of handle
file_close of handle

# Check file existence
exists is file_exists of "data.txt"

# List directory
files is list_dir of "."
```

### JSON System Design

**Approach**: Wrap Python's `json` module with proper type conversions

**Type Mapping**:
- EigenScript numbers → JSON numbers
- EigenScript strings → JSON strings
- EigenScript lists → JSON arrays
- EigenScript dicts (future) → JSON objects
- null vector → JSON null

**Example Usage**:
```eigenscript
# Parse JSON
json_str is '{"name": "Alice", "age": 30}'
data is json_parse of json_str

# Stringify
json_output is json_stringify of data
```

### Date/Time System Design

**Approach**: Wrap Python's `datetime` module

**Design Points**:
1. Use Unix timestamps as primary representation
2. Support ISO 8601 format strings
3. Provide component extractors
4. Support basic arithmetic (add/subtract seconds)

**Example Usage**:
```eigenscript
# Get current time
now is time_now of null

# Format time
formatted is time_format of [now, "%Y-%m-%d"]

# Parse time
timestamp is time_parse of ["2025-11-19", "%Y-%m-%d"]
```

### Enhanced List Operations Design

**Approach**: Add functional programming utilities

**Functions**:
1. `zip` - Combine multiple lists element-wise
2. `enumerate` - Add indices to list elements
3. `flatten` - Flatten nested lists
4. `reverse` - Reverse list order

**Example Usage**:
```eigenscript
# Zip two lists
list1 is [1, 2, 3]
list2 is ["a", "b", "c"]
zipped is zip of [list1, list2]  # [(1, "a"), (2, "b"), (3, "c")]

# Enumerate
items is ["apple", "banana"]
indexed is enumerate of items  # [(0, "apple"), (1, "banana")]
```

---

## Testing Strategy

### Coverage Target
- **Overall**: Maintain >78% coverage
- **New Functions**: Aim for >80% coverage on all new code
- **Integration**: Ensure new features work with existing language features

### Test Categories

#### File I/O Tests
1. Basic operations (open, read, write, close)
2. Error handling (file not found, permissions, etc.)
3. Path operations
4. Directory listing
5. File metadata (size, modification time)
6. Edge cases (empty files, large files, special characters)

#### JSON Tests
1. Parsing valid JSON (objects, arrays, primitives)
2. Parsing invalid JSON (error handling)
3. Stringify various types
4. Round-trip testing (parse → stringify → parse)
5. Nested structures
6. Special characters and Unicode

#### Date/Time Tests
1. Current time retrieval
2. Formatting with various format strings
3. Parsing various formats
4. Time arithmetic
5. Component extraction
6. Edge cases (leap years, timezones)

#### Enhanced List Tests
1. Zip with equal-length lists
2. Zip with unequal-length lists
3. Enumerate empty and non-empty lists
4. Flatten single-level and multi-level nesting
5. Reverse various list types

---

## Example Programs

### File Processing Example
```eigenscript
# Read and process a text file
define process_file as:
    handle is file_open of ["data.txt", "r"]
    content is file_read of handle
    file_close of handle
    
    lines is split of content
    print of "Processed lines:"
    print of (len of lines)
    
    return lines
```

### JSON Data Example
```eigenscript
# Load and manipulate JSON data
config_handle is file_open of ["config.json", "r"]
config_json is file_read of config_handle
file_close of config_handle

config is json_parse of config_json

print of "Application name:"
print of (config of "name")
```

### Date/Time Example
```eigenscript
# Calculate elapsed time
start is time_now of null

# Do some work...
result is factorial of 1000

end is time_now of null
elapsed is end - start

print of "Elapsed time (seconds):"
print of elapsed
```

### Enhanced List Example
```eigenscript
# Use zip and enumerate together
names is ["Alice", "Bob", "Charlie"]
ages is [30, 25, 35]

# Zip names and ages
pairs is zip of [names, ages]

# Enumerate the pairs
indexed_pairs is enumerate of pairs

print of "People with indices:"
print of indexed_pairs
```

---

## Implementation Order

### Day 1-2: File I/O (Highest Value)
1. Morning: Design and implement basic file operations
2. Afternoon: Implement path operations and directory listing
3. Write tests for all file operations
4. Create example programs

### Day 3: JSON Support (High Value, Quick Win)
1. Morning: Implement json_parse
2. Afternoon: Implement json_stringify
3. Write tests
4. Create examples

### Day 4-5: Date/Time Operations
1. Day 4 AM: Implement time_now, time_format
2. Day 4 PM: Implement time_parse, component extractors
3. Day 5 AM: Implement time arithmetic
4. Day 5 PM: Write tests and examples

### Day 6: Enhanced List Operations
1. Morning: Implement zip, enumerate
2. Afternoon: Implement flatten, reverse
3. Write tests and examples

### Day 7: Integration & Documentation
1. Full test suite run
2. Coverage verification
3. Documentation updates
4. Week 3 completion report

---

## Success Criteria

### Functional Requirements ✅
- [ ] All planned functions implemented
- [ ] All functions follow EigenScript syntax patterns
- [ ] Error handling is robust and helpful
- [ ] Functions integrate well with existing features

### Quality Requirements ✅
- [ ] >80% test coverage on new code
- [ ] All tests passing (351+ tests)
- [ ] Overall coverage maintained at >78%
- [ ] Code follows project style

### Documentation Requirements ✅
- [ ] All functions documented in code
- [ ] Example programs created
- [ ] README updated with new features
- [ ] PRODUCTION_ROADMAP updated

### User Experience Requirements ✅
- [ ] Functions are intuitive to use
- [ ] Error messages are clear
- [ ] Examples demonstrate practical use cases
- [ ] Integration with existing features is seamless

---

## Risk Mitigation

### Technical Risks
1. **File handle management**: Ensure proper cleanup to avoid resource leaks
   - Mitigation: Use try/finally blocks, consider context managers
   
2. **JSON type conversions**: EigenScript's vector-based types may not map cleanly
   - Mitigation: Clear documentation of type mappings, helpful error messages
   
3. **Date/Time timezone complexity**: Timezones are notoriously complex
   - Mitigation: Start with UTC/local time only, defer timezone support to Phase 6

### Process Risks
1. **Scope creep**: Easy to add "just one more feature"
   - Mitigation: Stick to planned features, track "nice-to-haves" for Phase 6
   
2. **Test coverage**: New code might lower overall coverage
   - Mitigation: Write tests before/during implementation, not after

---

## Progress Tracking

### Completed
- [x] Create implementation plan
- [x] Analyze existing codebase
- [x] Design function signatures

### In Progress
- [ ] File I/O implementation

### Blocked
- None

### Notes
- Starting with File I/O as highest value feature
- Will prioritize JSON next as it's a quick win
- Date/Time and Enhanced Lists are lower priority but still valuable

---

**Status**: Ready to begin implementation  
**Next Step**: Implement File I/O operations  
**Confidence**: HIGH 🚀
