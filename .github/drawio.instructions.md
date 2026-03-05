# Draw.io Diagram Generation Instructions

When the user asks to generate a diagram for Draw.io (or a .drawio file), follow these rules strictly to ensure the XML is valid and renderable.

## 1. Output Format
- Provide the output as a single block of XML.
- Use the standard mxGraph model schema.
- Do not add conversational text inside the code block.

## 2. XML Structure
The diagram must follow this nested structure:
<mxfile>
  <diagram id="unique_id" name="Page-1">
    <mxGraphModel dx="1000" dy="1000" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="827" pageHeight="1169" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        </root>
    </mxGraphModel>
  </diagram>
</mxfile>

## 3. Element Definitions
- **Nodes:** Every node must have a unique `id`, a `value` (label), and a `style`. 
- **Geometry:** Every node must have a `<mxGeometry>` child element with `x`, `y`, `width`, and `height` defined.
- **Edges:** Every edge must have a unique `id`, `source`, `target`, and `edge="1"`. It must contain a `<mxGeometry relative="1" as="geometry" />`.

## 4. Styling Guidelines
- Use `rounded=1;whiteSpace=wrap;html=1;` for standard rectangles.
- Use `ellipse;whiteSpace=wrap;html=1;` for circles/actors.
- For technical diagrams, use clean, modern colors (e.g., `fillColor=#dae8fe;strokeColor=#6c8ebf;`).

## 5. Layout Logic
- Automatically calculate coordinates (`x` and `y`) so that elements do not overlap.
- Space nodes at least 100 units apart.
- Use a top-to-bottom or left-to-right flow unless otherwise specified.