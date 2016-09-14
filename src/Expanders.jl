"""
Defines node "expanders" that transform nodes from the parsed markdown files.
"""
module Expanders

import ..Documenter:
    Anchors,
    Selectors,
    Builder,
    Documents,
    Formats,
    Documenter,
    Utilities

import .Documents:
    MethodNode,
    DocsNode,
    DocsNodes,
    EvalNode,
    MetaNode

using Compat


function expand(doc::Documents.Document)
    for (src, page) in doc.internal.pages
        empty!(page.globals.meta)
        for element in page.elements
            Selectors.dispatch(ExpanderPipeline, element, page, doc)
        end
    end
end


# Expander Pipeline.
# ------------------

"""
The default node expander "pipeline", which consists of the following expanders:

- [`TrackHeaders`](@ref)
- [`MetaBlocks`](@ref)
- [`DocsBlocks`](@ref)
- [`AutoDocsBlocks`](@ref)
- [`EvalBlocks`](@ref)
- [`IndexBlocks`](@ref)
- [`ContentsBlocks`](@ref)
- [`ExampleBlocks`](@ref)
- [`SetupBlocks`](@ref)
- [`REPLBlocks`](@ref)

"""
abstract ExpanderPipeline <: Selectors.AbstractSelector

"""
Tracks all `Markdown.Header` nodes found in the parsed markdown files and stores an
[`Anchors.Anchor`](@ref) object for each one.
"""
abstract TrackHeaders <: ExpanderPipeline

"""
Parses each code block where the language is `@meta` and evaluates the key/value pairs found
within the block, i.e.

````markdown
```@meta
CurrentModule = Documenter
DocTestSetup  = quote
    using Documenter
end
```
````
"""
abstract MetaBlocks <: ExpanderPipeline

"""
Parses each code block where the language is `@docs` and evaluates the expressions found
within the block. Replaces the block with the docstrings associated with each expression.

````markdown
```@docs
Documenter
makedocs
deploydocs
```
````
"""
abstract DocsBlocks <: ExpanderPipeline

"""
Parses each code block where the language is `@autodocs` and replaces it with all the
docstrings that match the provided key/value pairs `Modules = ...` and `Order = ...`.

````markdown
```@autodocs
Modules = [Foo, Bar]
Order   = [:function, :type]
```
````
"""
abstract AutoDocsBlocks <: ExpanderPipeline

"""
Parses each code block where the language is `@eval` and evaluates it's content. Replaces
the block with the value resulting from the evaluation. This can be useful for inserting
generated content into a document such as plots.

````markdown
```@eval
using PyPlot
x = linspace(-π, π)
y = sin(x)
plot(x, y, color = "red")
savefig("plot.svg")
Markdown.parse("![Plot](plot.svg)")
```
````
"""
abstract EvalBlocks <: ExpanderPipeline

"""
Parses each code block where the language is `@index` and replaces it with an index of all
docstrings spliced into the document. The pages that are included can be set using a
key/value pair `Pages = [...]` such as

````markdown
```@index
Pages = ["foo.md", "bar.md"]
```
````
"""
abstract IndexBlocks <: ExpanderPipeline

"""
Parses each code block where the language is `@contents` and replaces it with a nested list
of all `Header` nodes in the generated document. The pages and depth of the list can be set
using `Pages = [...]` and `Depth = N` where `N` is and integer.

````markdown
```@contents
Pages = ["foo.md", "bar.md"]
Depth = 1
```
````
The default `Depth` value is `2`.
"""
abstract ContentsBlocks <: ExpanderPipeline

"""
Parses each code block where the language is `@example` and evaluates the parsed Julia code
found within. The resulting value is then inserted into the final document after the source
code.

````markdown
```@example
a = 1
b = 2
a + b
```
````
"""
abstract ExampleBlocks <: ExpanderPipeline

"""
Similar to the [`ExampleBlocks`](@ref) expander, but inserts a Julia REPL prompt before each
toplevel expression in the final document.
"""
abstract REPLBlocks <: ExpanderPipeline

"""
Similar to the [`ExampleBlocks`](@ref) expander, but hides all output in the final document.
"""
abstract SetupBlocks <: ExpanderPipeline

Selectors.order(::Type{TrackHeaders})   = 1.0
Selectors.order(::Type{MetaBlocks})     = 2.0
Selectors.order(::Type{DocsBlocks})     = 3.0
Selectors.order(::Type{AutoDocsBlocks}) = 4.0
Selectors.order(::Type{EvalBlocks})     = 5.0
Selectors.order(::Type{IndexBlocks})    = 6.0
Selectors.order(::Type{ContentsBlocks}) = 7.0
Selectors.order(::Type{ExampleBlocks})  = 8.0
Selectors.order(::Type{REPLBlocks})     = 9.0
Selectors.order(::Type{SetupBlocks})     = 10.0

Selectors.matcher(::Type{TrackHeaders},   node, page, doc) = isa(node, Markdown.Header)
Selectors.matcher(::Type{MetaBlocks},     node, page, doc) = iscode(node, "@meta")
Selectors.matcher(::Type{DocsBlocks},     node, page, doc) = iscode(node, "@docs")
Selectors.matcher(::Type{AutoDocsBlocks}, node, page, doc) = iscode(node, "@autodocs")
Selectors.matcher(::Type{EvalBlocks},     node, page, doc) = iscode(node, "@eval")
Selectors.matcher(::Type{IndexBlocks},    node, page, doc) = iscode(node, "@index")
Selectors.matcher(::Type{ContentsBlocks}, node, page, doc) = iscode(node, "@contents")
Selectors.matcher(::Type{ExampleBlocks},  node, page, doc) = iscode(node, r"^@example")
Selectors.matcher(::Type{REPLBlocks},     node, page, doc) = iscode(node, r"^@repl")
Selectors.matcher(::Type{SetupBlocks},     node, page, doc) = iscode(node, r"^@setup")

# Default Expander.

Selectors.runner(::Type{ExpanderPipeline}, x, page, doc) = page.mapping[x] = x

# Track Headers.
# --------------

function Selectors.runner(::Type{TrackHeaders}, header, page, doc)
    # Get the header slug.
    text =
        if namedheader(header)
            url = header.text[1].url
            header.text = header.text[1].text
            match(NAMEDHEADER_REGEX, url)[1]
        else
            sprint(Markdown.plain, Markdown.Paragraph(header.text))
        end
    slug = Utilities.slugify(text)
    # Add the header to the document's header map.
    anchor = Anchors.add!(doc.internal.headers, header, slug, page.build)
    # Map the header element to the generated anchor and the current anchor count.
    page.mapping[header] = anchor
end

# @meta
# -----

function Selectors.runner(::Type{MetaBlocks}, x, page, doc)
    meta = page.globals.meta
    for (ex, str) in Utilities.parseblock(x.code, doc, page)
        if Utilities.isassign(ex)
            try
                meta[ex.args[1]] = eval(current_module(), ex.args[2])
            catch err
                Utilities.warn(doc, page, "Failed to evaluate `$(strip(str))` in `@meta` block.", err)
            end
        end
    end
    page.mapping[x] = MetaNode(copy(meta))
end

# @docs
# -----

function Selectors.runner(::Type{DocsBlocks}, x, page, doc)
    failed = false
    nodes  = DocsNode[]
    curmod = get(page.globals.meta, :CurrentModule, current_module())
    for (ex, str) in Utilities.parseblock(x.code, doc, page)
        local binding = try
            Documenter.DocSystem.binding(curmod, ex)
        catch err
            Utilities.warn(page.source, "Unable to get the binding for '$(strip(str))'.", err, ex, curmod)
            failed = true
            continue
        end
        # Undefined `Bindings` get discarded.
        if !Documenter.DocSystem.iskeyword(binding) && !Documenter.DocSystem.defined(binding)
            Utilities.warn(page.source, "Undefined binding '$(binding)'.")
            failed = true
            continue
        end
        local typesig = eval(curmod, Documenter.DocSystem.signature(ex, str))

        local object = Utilities.Object(binding, typesig)
        # We can't include the same object more than once in a document.
        if haskey(doc.internal.objects, object)
            Utilities.warn(page.source, "Duplicate docs found for '$(strip(str))'.")
            failed = true
            continue
        end

        # Find the docs matching `binding` and `typesig`. Only search within the provided modules.
        local docs = Documenter.DocSystem.getdocs(binding, typesig; modules = doc.user.modules)

        # Include only docstrings from user-provided modules if provided.
        if !isempty(doc.user.modules)
            filter!(d -> d.data[:module] in doc.user.modules, docs)
        end

        # Check that we aren't printing an empty docs list. Skip block when empty.
        if isempty(docs)
            Utilities.warn(page.source, "No docs found for '$(strip(str))'.")
            failed = true
            continue
        end

        # Concatenate found docstrings into a single `MD` object.
        local docstr = Base.Markdown.MD(map(Documenter.DocSystem.parsedoc, docs))
        docstr.meta[:results] = docs

        # Generate a unique name to be used in anchors and links for the docstring.
        local slug = Utilities.slugify(object)
        local anchor = Anchors.add!(doc.internal.docs, object, slug, page.build)
        local docsnode = DocsNode(docstr, anchor, object, page)

        # Track the order of insertion of objects per-binding.
        push!(get!(doc.internal.bindings, binding, Utilities.Object[]), object)

        doc.internal.objects[object] = docsnode
        push!(nodes, docsnode)
    end
    # When a `@docs` block fails we need to remove the `.language` since some markdown
    # parsers have trouble rendering it correctly.
    page.mapping[x] = failed ? (x.language = ""; x) : DocsNodes(nodes)
end

# @autodocs
# ---------

const AUTODOCS_DEFAULT_ORDER = [:module, :constant, :type, :function, :macro]

function Selectors.runner(::Type{AutoDocsBlocks}, x, page, doc)
    curmod = get(page.globals.meta, :CurrentModule, current_module())
    fields = Dict{Symbol, Any}()
    for (ex, str) in Utilities.parseblock(x.code, doc, page)
        if Utilities.isassign(ex)
            try
                fields[ex.args[1]] = eval(curmod, ex.args[2])
            catch err
                Utilities.warn(doc, page, "Failed to evaluate `$(strip(str))` in `@autodocs` block.", err)
            end
        end
    end
    if haskey(fields, :Modules)
        # Gather and filter docstrings.
        local modules = fields[:Modules]
        local order = get(fields, :Order, AUTODOCS_DEFAULT_ORDER)
        local pages = get(fields, :Pages, [])
        local public = get(fields, :Public, true)
        local private = get(fields, :Private, true)
        local results = []
        for mod in modules
            for (binding, multidoc) in Documenter.DocSystem.getmeta(mod)
                # Which bindings should be included?
                local isexported = Base.isexported(mod, binding.var)
                local included = (isexported && public) || (!isexported && private)
                # What category does the binding belong to?
                local category = Documenter.DocSystem.category(binding)
                if category in order && included
                    for (typesig, docstr) in multidoc.docs
                        local path = docstr.data[:path]
                        local object = Utilities.Object(binding, typesig)
                        if isempty(pages)
                            push!(results, (mod, path, category, object, isexported, docstr))
                        else
                            for p in pages
                                if endswith(path, p)
                                    push!(results, (mod, p, category, object, isexported, docstr))
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        # Sort docstrings.
        local modulemap = Documents.precedence(modules)
        local pagesmap = Documents.precedence(pages)
        local ordermap = Documents.precedence(order)
        local comparison = function (a, b)
            local t
            (t = Documents._compare(modulemap, 1, a, b)) == 0 || return t < 0 # module
            a[5] == b[5] || return a[5] > b[5] # exported bindings before unexported ones.
            (t = Documents._compare(pagesmap,  2, a, b)) == 0 || return t < 0 # page
            (t = Documents._compare(ordermap,  3, a, b)) == 0 || return t < 0 # category
            string(a[4]) < string(b[4])                                       # name
        end
        sort!(results; lt = comparison)

        # Finalise docstrings.
        nodes = DocsNode[]
        for (mod, path, category, object, isexported, docstr) in results
            if haskey(doc.internal.objects, object)
                Utilities.warn(page.source, "Duplicate docs found for '$(object.binding)'.")
                continue
            end
            local markdown = Markdown.MD(Documenter.DocSystem.parsedoc(docstr))
            markdown.meta[:results] = [docstr]
            local slug = Utilities.slugify(object)
            local anchor = Anchors.add!(doc.internal.docs, object, slug, page.build)
            local docsnode = DocsNode(markdown, anchor, object, page)

            # Track the order of insertion of objects per-binding.
            push!(get!(doc.internal.bindings, object.binding, Utilities.Object[]), object)

            doc.internal.objects[object] = docsnode
            push!(nodes, docsnode)
        end
        page.mapping[x] = DocsNodes(nodes)
    else
        Utilities.warn(page.source, "'@autodocs' missing 'Modules = ...'.")
        page.mapping[x] = x
    end
end

# @eval
# -----

function Selectors.runner(::Type{EvalBlocks}, x, page, doc)
    sandbox = Module(:EvalBlockSandbox)
    cd(dirname(page.build)) do
        result = nothing
        for (ex, str) in Utilities.parseblock(x.code, doc, page)
            try
                result = eval(sandbox, ex)
            catch err
                Utilities.warn(doc, page, "Failed to evaluate `@eval` block.", err)
            end
        end
        page.mapping[x] = EvalNode(x, result)
    end
end

# @index
# ------

function Selectors.runner(::Type{IndexBlocks}, x, page, doc)
    node = Documents.buildnode(Documents.IndexNode, x, doc, page)
    push!(doc.internal.indexnodes, node)
    page.mapping[x] = node
end

# @contents
# ---------

function Selectors.runner(::Type{ContentsBlocks}, x, page, doc)
    node = Documents.buildnode(Documents.ContentsNode, x, doc, page)
    push!(doc.internal.contentsnodes, node)
    page.mapping[x] = node
end

# @example
# --------

function Selectors.runner(::Type{ExampleBlocks}, x, page, doc)
    matched = Utilities.nullmatch(r"^@example[ ]?(.*)$", x.language)
    isnull(matched) && error("invalid '@example' syntax: $(x.language)")
    # The sandboxed module -- either a new one or a cached one from this page.
    name = Utilities.getmatch(matched, 1)
    sym  = isempty(name) ? gensym("ex-") : Symbol("ex-", name)
    mod  = get!(page.globals.meta, sym, Module(sym))::Module
    # Evaluate the code block. We redirect STDOUT/STDERR to `buffer`.
    result, buffer = nothing, IOBuffer()
    for (ex, str) in Utilities.parseblock(x.code, doc, page)
        (value, success, backtrace, text) = Utilities.withoutput() do
            cd(dirname(page.build)) do
                eval(mod, :(ans = $(eval(mod, ex))))
            end
        end
        result = value
        print(buffer, text)
        if !success
            Utilities.warn(page.source, "failed to run code block.\n\n$(value)")
            page.mapping[x] = x
            return
        end
    end
    # Splice the input and output into the document.
    content = []
    input   = droplines(x.code)

    # Special-case support for displaying SVG graphics. TODO: make this more general.
    output = mimewritable(MIME"image/svg+xml"(), result) ?
        Documents.RawHTML(stringmime(MIME"image/svg+xml"(), result)) :
        Markdown.Code(Documenter.DocChecks.result_to_string(buffer, result))

    # Only add content when there's actually something to add.
    isempty(input)  || push!(content, Markdown.Code("julia", input))
    isempty(output.code) || push!(content, output)
    # ... and finally map the original code block to the newly generated ones.
    page.mapping[x] = Markdown.MD(content)
end

# @repl
# -----

function Selectors.runner(::Type{REPLBlocks}, x, page, doc)
    matched = Utilities.nullmatch(r"^@repl[ ]?(.*)$", x.language)
    isnull(matched) && error("invalid '@repl' syntax: $(x.language)")
    name = Utilities.getmatch(matched, 1)
    sym  = isempty(name) ? gensym("repl-") : Symbol("repl-", name)
    mod  = get!(page.globals.meta, sym, Module(sym))::Module
    code = split(x.code, '\n'; limit = 2)[end]
    result, out = nothing, IOBuffer()
    for (ex, str) in Utilities.parseblock(x.code, doc, page)
        buffer = IOBuffer()
        input  = droplines(str)
        (value, success, backtrace, text) = Utilities.withoutput() do
            cd(dirname(page.build)) do
                eval(mod, :(ans = $(eval(mod, ex))))
            end
        end
        result = value
        print(out, text)
        local output = if success
            hide = Documenter.DocChecks.ends_with_semicolon(input)
            Documenter.DocChecks.result_to_string(buffer, hide ? nothing : value)
        else
            Documenter.DocChecks.error_to_string(buffer, value, [])
        end
        isempty(input) || println(out, prepend_prompt(input))
        if isempty(input) || isempty(output)
            println(out)
        else
            println(out, output, "\n")
        end
    end
    page.mapping[x] = Base.Markdown.Code("julia", rstrip(takebuf_string(out)))
end

# @setup
# --------

function Selectors.runner(::Type{SetupBlocks}, x, page, doc)
    matched = Utilities.nullmatch(r"^@setup[ ](.+)$", x.language)
    isnull(matched) && error("invalid '@setup <name>' syntax: $(x.language)")
    # The sandboxed module -- either a new one or a cached one from this page.
    name = Utilities.getmatch(matched, 1)
    sym  = isempty(name) ? gensym("ex-") : Symbol("ex-", name)
    mod  = get!(page.globals.meta, sym, Module(sym))::Module

    # Evaluate whole @setup block at once instead of piecewise
    page.mapping[x] =
    try
        cd(dirname(page.build)) do
            eval(mod, :(include_string($(x.code))))
        end
        Markdown.MD([])
    catch err
        Utilities.warn(page.source, "failed to run `@setup` block.\n\n$(err)")
        x
    end
    # ... and finally map the original code block to the newly generated ones.
    page.mapping[x] = Markdown.MD([])
end

# Utilities.
# ----------

iscode(x::Markdown.Code, r::Regex) = ismatch(r, x.language)
iscode(x::Markdown.Code, lang)     = x.language == lang
iscode(x, lang)                    = false

const NAMEDHEADER_REGEX = r"^@id (.+)$"

function namedheader(h::Markdown.Header)
    if isa(h.text, Vector) && length(h.text) === 1 && isa(h.text[1], Markdown.Link)
        url = h.text[1].url
        ismatch(NAMEDHEADER_REGEX, url)
    else
        false
    end
end

# Remove any `# hide` lines, leading/trailing blank lines, and trailing whitespace.
function droplines(code; skip = 0)
    buffer = IOBuffer()
    for line in split(code, '\n')[(skip + 1):end]
        ismatch(r"^(.*)# hide$", line) && continue
        println(buffer, rstrip(line))
    end
    strip(takebuf_string(buffer), '\n')
end

function prepend_prompt(input)
    prompt  = "julia> "
    padding = " "^length(prompt)
    out = IOBuffer()
    for (n, line) in enumerate(split(input, '\n'))
        line = rstrip(line)
        println(out, n == 1 ? prompt : padding, line)
    end
    rstrip(takebuf_string(out))
end

end