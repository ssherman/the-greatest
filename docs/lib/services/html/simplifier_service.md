# Services::Html::SimplifierService

## Summary
HTML cleaning and simplification service that strips unnecessary markup from raw HTML while preserving semantic structure. Designed to prepare HTML lists for AI parsing by removing noise, scripts, media elements, and styling while keeping essential content and structural elements.

## Public Methods

### `self.call(raw_html)`
Class method for convenient HTML simplification
- Parameters: `raw_html` (String) - Raw HTML content to simplify
- Returns: String of simplified HTML, or nil if input is blank
- Usage: Direct class method call for stateless operation

### `#initialize(raw_html)`
Creates service instance with HTML content
- Parameters: `raw_html` (String) - Raw HTML content to process
- Purpose: Instance-based approach for more complex processing scenarios

### `#call`
Executes HTML simplification process
- Returns: String of simplified HTML, or nil if @raw_html is blank
- Process: Parses HTML, removes unwanted elements, strips attributes
- Error handling: Returns nil for blank input, handles malformed HTML gracefully

## Private Methods

### `#simplify_node(node)`
Main simplification logic for HTML nodes
- Parameters: `node` (Nokogiri::XML::Node) - Document fragment to process
- Returns: Modified node with simplified structure
- Process: Removes unwanted tags, then strips non-essential attributes
- Side effects: Modifies node structure in place

### `#remove_unwanted_tags(doc)`
Removes problematic HTML elements that interfere with list parsing
- Parameters: `doc` (Nokogiri::XML::DocumentFragment) - Document to clean
- Side effects: Removes unwanted elements from document tree
- Strategy: Bulk removal of predefined tag categories

## HTML Processing Strategy

### Unwanted Tag Categories
The service removes these categories of HTML elements:

#### Scripts and Styles
- `script`, `style`, `link`, `meta`, `noscript`
- Purpose: Remove non-content elements that add parsing noise

#### Media Elements  
- `img`, `picture`, `audio`, `video`, `source`, `track`, `canvas`, `svg`
- Purpose: Media elements don't contribute to list item text extraction

#### Interactive Elements
- `button`, `form`, `input`, `select`, `textarea`, `label`, `fieldset`, `legend`, `optgroup`, `option`, `datalist`, `output`, `progress`, `meter`
- Purpose: Form controls and interactive elements are irrelevant for list parsing

#### Embedded Content
- `iframe`, `embed`, `object`, `param`, `map`, `area`
- Purpose: External embedded content doesn't contain list items

#### Semantic but Unwanted
- `figure`, `figcaption`, `dialog`, `menu`, `menuitem`, `details`, `summary`, `slot`, `template`
- Purpose: These may wrap content but don't contribute to list structure

#### Navigation and Structure
- `nav`, `aside`, `footer`, `header`
- Purpose: Site navigation elements often confuse list parsing

#### Specialized Elements
- `ruby`, `rt`, `rp` (Ruby annotations)
- `time`, `data` (Temporal/data elements)
- `abbr`, `dfn` (Abbreviations and definitions)
- `code`, `pre`, `samp`, `kbd`, `var` (Code elements)
- `blockquote`, `q`, `cite` (Quote elements)

### Preserved Attributes
Only essential attributes are kept during simplification:
- `id` - Element identification
- `class` - CSS class names (may contain semantic info)
- `href` - Link destinations
- `src` - Resource sources
- `alt` - Alternative text
- `title` - Element titles

All other attributes (style, onclick, data-*, etc.) are removed.

## Preserved HTML Structure

### Essential Elements Kept
The service preserves these elements crucial for list parsing:
- `ul`, `ol`, `li` - List structure
- `table`, `thead`, `tbody`, `tfoot`, `tr`, `td`, `th`, `caption`, `colgroup`, `col` - Table structure (for Wikipedia-style tabular lists)
- `div`, `span` - Generic containers
- `p` - Paragraphs
- `h1`-`h6` - Headings
- `a` - Links (may contain item titles)
- `strong`, `b`, `em`, `i` - Text formatting
- `br` - Line breaks

### Text Content
- All text nodes are preserved
- Whitespace handling follows Nokogiri defaults
- HTML entities are properly decoded

## Usage Examples

### Basic Usage
```ruby
raw_html = "<div><script>alert('hi')</script><ul><li>Item 1</li></ul></div>"
simplified = Services::Html::SimplifierService.call(raw_html)
# Returns: "<div><ul><li>Item 1</li></ul></div>"
```

### With Complex HTML
```ruby
complex_html = <<~HTML
  <div class="list-container" style="color: red;">
    <nav>Navigation</nav>
    <ul id="main-list">
      <li data-id="1" onclick="track()">
        <img src="cover.jpg" alt="Album cover">
        <strong>Album Title</strong> - Artist Name
      </li>
    </ul>
  </div>
HTML

simplified = Services::Html::SimplifierService.call(complex_html)
# Returns: "<div class=\"list-container\"><ul id=\"main-list\"><li><strong>Album Title</strong> - Artist Name</li></ul></div>"
```

### With Wikipedia-style Tables
```ruby
table_html = <<~HTML
  <div>
    <script>trackView()</script>
    <table class="wikitable">
      <tr><th>Rank</th><th>Album</th><th>Artist</th></tr>
      <tr><td>1</td><td>Abbey Road</td><td>Beatles</td></tr>
    </table>
  </div>
HTML

simplified = Services::Html::SimplifierService.call(table_html)
# Returns: "<div><table class=\"wikitable\"><tr><th>Rank</th><th>Album</th><th>Artist</th></tr><tr><td>1</td><td>Abbey Road</td><td>Beatles</td></tr></table></div>"
```

### Instance-based Usage
```ruby
service = Services::Html::SimplifierService.new(raw_html)
simplified = service.call
```

### Integration with List Processing
```ruby
list = List.find(123)
simplified_html = Services::Html::SimplifierService.call(list.raw_html)
list.update!(simplified_html: simplified_html)
```

## Error Handling
- **Blank Input**: Returns nil for blank or nil input
- **Malformed HTML**: Nokogiri handles malformed HTML gracefully
- **Empty Result**: May return empty string if all content was removed
- **Encoding Issues**: Nokogiri handles various encodings automatically

## Performance Considerations
- **Single Pass**: Removes all unwanted tags in one CSS selector operation
- **In-Place Modification**: Modifies DOM tree directly for memory efficiency  
- **Nokogiri Efficiency**: Uses DocumentFragment for faster parsing than full document
- **Attribute Stripping**: Traverses tree once for attribute cleaning

## Design Rationale

### Why Remove So Many Elements?
The aggressive tag removal strategy serves AI parsing:
- **Reduces Noise**: Fewer irrelevant elements for AI to process
- **Improves Accuracy**: AI focuses on actual list content
- **Faster Processing**: Less HTML to analyze
- **Cost Efficiency**: Smaller token count for AI APIs

### Why Keep Essential Attributes?
Preserved attributes provide contextual information:
- **ID/Class**: May indicate semantic importance
- **HREF**: Links often contain item titles or references
- **ALT/Title**: May contain descriptive text

### Why Not Use Readability Algorithms?
Purpose-built for list extraction rather than general readability:
- **List-Specific**: Optimized for list structures rather than articles
- **Aggressive Cleaning**: Removes more than readability would
- **Predictable Output**: Consistent results for AI processing

## Dependencies
- **Nokogiri**: HTML parsing and manipulation
- **Ruby Standard Library**: String handling and utilities

## Integration Points
- Used by Services::Lists::ImportService for HTML preprocessing
- Input: List model's raw_html field
- Output: Stored in List model's simplified_html field
- Followed by: AI parsing tasks for content extraction

## Future Considerations
- Could add configurable tag removal lists per media type
- May benefit from caching for repeated processing
- Could integrate with HTML validation before processing
- Potential for parallel processing of large HTML documents