if Code.ensure_loaded?(Kino.JS) do
  defmodule Runic.Kino.Mermaid do
    @moduledoc """
    Kino widget for rendering Runic Workflows as Mermaid diagrams in LiveBook.

    Requires the optional `kino` dependency.

    ## Usage

        # Render workflow as flowchart
        Runic.Kino.Mermaid.new(workflow)

        # With options
        Runic.Kino.Mermaid.new(workflow, direction: :LR, include_memory: true)

        # Render causal sequence diagram
        Runic.Kino.Mermaid.sequence(workflow)

        # Render raw Mermaid code
        Runic.Kino.Mermaid.render("flowchart TB\\n    A --> B")
    """

    use Kino.JS

    alias Runic.Workflow

    @doc """
    Creates a new Mermaid diagram from a Runic Workflow.
    """
    def new(%Workflow{} = workflow, opts \\ []) do
      mermaid_code = Workflow.to_mermaid(workflow, opts)
      render(mermaid_code)
    end

    @doc """
    Creates a sequence diagram showing causal reactions in the workflow.
    """
    def sequence(%Workflow{} = workflow, opts \\ []) do
      mermaid_code = Workflow.to_mermaid_sequence(workflow, opts)
      render(mermaid_code)
    end

    @doc """
    Renders raw Mermaid code.
    """
    def render(mermaid_code) when is_binary(mermaid_code) do
      Kino.JS.new(__MODULE__, mermaid_code)
    end

    asset "main.js" do
      """
      export async function init(ctx, graph) {
        ctx.root.style.background = '#1a1a2e';
        ctx.root.style.padding = '16px';
        ctx.root.style.borderRadius = '8px';
        ctx.root.style.minHeight = '200px';

        const container = document.createElement('div');
        container.id = 'mermaid-' + Math.random().toString(36).substr(2, 9);
        ctx.root.appendChild(container);

        try {
          const mermaid = await import("https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs");

          mermaid.default.initialize({
            startOnLoad: false,
            theme: 'dark',
            themeVariables: {
              background: '#1a1a2e',
              primaryColor: '#2d3748',
              primaryTextColor: '#fff',
              primaryBorderColor: '#4fd1c5',
              lineColor: '#4fd1c5',
              secondaryColor: '#553c9a',
              tertiaryColor: '#1e3a5f'
            },
            flowchart: {
              htmlLabels: true,
              curve: 'basis'
            },
            sequence: {
              actorMargin: 50,
              showSequenceNumbers: true
            }
          });

          const { svg, bindFunctions } = await mermaid.default.render(container.id + '-svg', graph);
          container.innerHTML = svg;
          if (bindFunctions) {
            bindFunctions(container);
          }
        } catch (error) {
          container.innerHTML = '<pre style="color: #fc8181; padding: 10px;">Error rendering diagram: ' + error.message + '</pre>';
          console.error('Mermaid render error:', error);
        }
      }
      """
    end
  end

  defmodule Runic.Kino.Cytoscape do
    @moduledoc """
    Kino widget for rendering Runic Workflows as Cytoscape.js graphs in LiveBook.

    Provides interactive pan/zoom and node selection.

    ## Usage

        # Render workflow
        Runic.Kino.Cytoscape.new(workflow)

        # With layout options
        Runic.Kino.Cytoscape.new(workflow, layout: :dagre)

        # Render raw Cytoscape elements
        Runic.Kino.Cytoscape.render(elements)
    """

    use Kino.JS

    alias Runic.Workflow

    @default_opts [
      layout: :breadthfirst,
      include_memory: false
    ]

    @doc """
    Creates a new Cytoscape graph from a Runic Workflow.
    """
    def new(%Workflow{} = workflow, opts \\ []) do
      opts = Keyword.merge(@default_opts, opts)
      elements = Workflow.to_cytoscape(workflow, opts)
      render(elements, opts)
    end

    @doc """
    Renders raw Cytoscape.js elements.
    """
    def render(elements, opts \\ []) when is_list(elements) do
      opts = Keyword.merge(@default_opts, opts)

      config = %{
        elements: elements,
        layout_options: layout_config(opts[:layout])
      }

      Kino.JS.new(__MODULE__, config)
    end

    defp layout_config(:dagre) do
      %{
        name: "dagre",
        rankDir: "TB",
        nodeSep: 50,
        rankSep: 80,
        fit: true,
        padding: 30
      }
    end

    defp layout_config(:breadthfirst) do
      %{
        name: "breadthfirst",
        fit: true,
        directed: true,
        padding: 30,
        spacingFactor: 1.2,
        avoidOverlap: true,
        circle: false
      }
    end

    defp layout_config(:cose) do
      %{
        name: "cose",
        fit: true,
        padding: 30,
        nodeRepulsion: 8000,
        idealEdgeLength: 100,
        nodeOverlap: 20
      }
    end

    defp layout_config(:grid) do
      %{
        name: "grid",
        fit: true,
        padding: 30,
        avoidOverlap: true,
        condense: true
      }
    end

    defp layout_config(_), do: layout_config(:breadthfirst)

    asset "main.js" do
      """
      import "https://cdn.jsdelivr.net/npm/cytoscape@3.26.0/dist/cytoscape.min.js";

      export function init(ctx, config) {
        ctx.root.style.width = '100%';
        ctx.root.style.height = '500px';
        ctx.root.style.background = '#1a1a2e';
        ctx.root.style.borderRadius = '8px';

        const cy = cytoscape({
          container: ctx.root,
          elements: config.elements,
          style: [
            {
              selector: 'node',
              style: {
                'background-color': 'data(background_color)',
                'label': 'data(name)',
                'color': '#fff',
                'text-valign': 'center',
                'text-halign': 'center',
                'font-size': '11px',
                'text-wrap': 'wrap',
                'text-max-width': '80px',
                'width': 100,
                'height': 50,
                'shape': 'data(shape)',
                'border-width': 2,
                'border-color': '#4fd1c5'
              }
            },
            {
              selector: 'node[?is_component]',
              style: {
                'background-opacity': 0.3,
                'border-style': 'dashed',
                'padding': '20px'
              }
            },
            {
              selector: 'edge',
              style: {
                'width': 2,
                'line-color': '#4fd1c5',
                'target-arrow-color': '#4fd1c5',
                'target-arrow-shape': 'triangle',
                'curve-style': 'bezier',
                'label': 'data(label)',
                'font-size': '9px',
                'color': '#a0aec0'
              }
            },
            {
              selector: 'edge[edge_type="causal"]',
              style: {
                'line-style': 'dashed',
                'line-color': '#a0aec0'
              }
            },
            {
              selector: ':selected',
              style: {
                'border-color': '#f6ad55',
                'border-width': 3
              }
            }
          ],
          layout: config.layout_options,
          zoomingEnabled: true,
          userZoomingEnabled: true,
          panningEnabled: true,
          userPanningEnabled: true,
          boxSelectionEnabled: false
        });

        // Fit on load
        cy.fit(30);

        // Add click handler for node info
        cy.on('tap', 'node', function(evt) {
          const node = evt.target;
          console.log('Node clicked:', node.data());
        });
      }
      """
    end
  end
end
