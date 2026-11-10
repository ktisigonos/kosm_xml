# kosm_xml

XML for kosm: the `xml` adapter writes whole XML files through `output.generate`. It claims
`.xml`; files with another extension (fontconfig's `.conf`) pass `.lang = "xml"`. It knows no
app, and cannot edit existing files yet.

## How values become XML

| Value | XML |
|---|---|
| the root table | `<?xml version="1.0"?>`, then its one root element |
| a root key starting with `!` | a declaration before the root element: `"!DOCTYPE"` = `kosm.raw("fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\"")` |
| a table | an element holding its entries as child elements, or `<name/>` when it has none |
| a key starting with `@` | an attribute of the enclosing element: `.@"@binding" = "strong"` |
| a list | its element repeated once per item, in order |
| a string, number, boolean or color | the element's text, escaped |
| `kosm.raw` text | written verbatim |

```zig
try output.generate(.{ .file = "~/.config/fontconfig/conf.d/50-kosm.conf", .lang = "xml" }, .{
    .fontconfig = .{ .alias = .{ .family = "monospace", .prefer = .{ .family = .{ "Iosevka", "Noto Color Emoji" } } } },
});
```

writes

```xml
<?xml version="1.0"?>
<fontconfig>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>Iosevka</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
</fontconfig>
```

An element cannot hold both text and child elements.
