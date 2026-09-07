#pragma once
#if !defined( RIPWIRE_INGEST_TU )
#error "ingest_jsimports.h belongs only to ingest.cpp"
#endif

namespace rw
{
namespace
{

// ES named imports carry three independent facts: local spelling, export spelling, and module.
//
// EXPORTS come in two shapes and BOTH are recorded, because the table is consulted as a REFUSAL: a name
// the table cannot find is a call the resolver declines to hand to the global name ladder. Seeing only
// the declaration form (`export function f(){}`) therefore does not merely miss `export { f }` — it
// DELETES the edge the ladder used to resolve correctly, which is a regression, not a gap. So:
//   * declaration form   `export function f(){}` / `export const f = () => {}` — the span is the
//                        declaration itself, and only a symbol INSIDE it may be the export.
//   * clause form        `export { f }` / `export { f as g }` — the exported name is the alias, the
//                        binding it names is module-scoped and declared ANYWHERE in the file, so the
//                        span is the whole program. `var` is the EXPORTED name (what an importer
//                        writes) and `importedName` the LOCAL one (what the definition is called).
// Re-export/barrel clauses (`export { f } from './m.js'`) are deliberately NOT recorded: the definition
// lives in a third file this table does not chase, so recording the name would let a refusal fire on
// evidence we do not have. Left out, the name is simply UNLISTED, and buildJsImportTables degrades an
// unlisted import to the name ladder — the pre-import behaviour, which resolved barrels correctly.
// `export default` is likewise absent, and so is its import side: a default import is an `identifier`
// child of the import_clause, not an `import_specifier`, so no JsImport binding is recorded for it and
// the whole default-export path stays on the unchanged name ladder rather than on a half-built table.
// Type-only imports remain a known gap (recorded with an empty importedName, and refused, never sprayed).
inline bool jsNodeIs( TSNode node, const char* kind )
{
    return !ts_node_is_null( node ) && std::strcmp( ts_node_type( node ), kind ) == 0;
}

inline bool jsHasToken( TSNode node, const char* token )
{
    ChildCursor cursor( node );
    std::vector<TSNode> children;
    collectChildren( node, cursor.cur, children );
    for( TSNode child : children )
    {
        if( jsNodeIs( child, token ) ) { return true; }
    }
    return false;
}

inline bool jsFunctionScope( TSNode node )
{
    const char* kind = ts_node_type( node );
    return std::strcmp( kind, "function_declaration" ) == 0 || std::strcmp( kind, "function_expression" ) == 0
        || std::strcmp( kind, "generator_function_declaration" ) == 0 || std::strcmp( kind, "generator_function" ) == 0
        || std::strcmp( kind, "arrow_function" ) == 0 || std::strcmp( kind, "method_definition" ) == 0;
}

// Walk binding PATTERNS, never initializer expressions or type annotations. Destructuring keys do not bind.
inline std::vector<std::string> jsPatternNames( TSNode pattern, std::string_view src )
{
    std::vector<std::string> names;
    std::vector<TSNode> pending;
    if( !ts_node_is_null( pattern ) ) { pending.push_back( pattern ); }
    while( !pending.empty() )
    {
        TSNode node = pending.back();
        pending.pop_back();
        const char* kind = ts_node_type( node );
        if( jsNodeIs( node, "identifier" ) || jsNodeIs( node, "shorthand_property_identifier_pattern" ) )
        {
            names.emplace_back( pattern::nodeText( node, src ) );
        }
        else if( jsNodeIs( node, "pair_pattern" ) || jsNodeIs( node, "assignment_pattern" )
                 || jsNodeIs( node, "object_assignment_pattern" ) || jsNodeIs( node, "required_parameter" ) || jsNodeIs( node, "optional_parameter" ) )
        {
            const char* field = jsNodeIs( node, "pair_pattern" ) ? "value"
                              : ( jsNodeIs( node, "required_parameter" ) || jsNodeIs( node, "optional_parameter" ) ) ? "pattern" : "left";
            TSNode child = ts_node_child_by_field_name( node, field, std::strlen( field ) );
            if( ts_node_is_null( child ) ) { child = ts_node_child_by_field_name( node, "name", 4 ); }
            if( !ts_node_is_null( child ) ) { pending.push_back( child ); }
        }
        else if( std::strcmp( kind, "formal_parameters" ) == 0 || std::strcmp( kind, "array_pattern" ) == 0
                 || std::strcmp( kind, "object_pattern" ) == 0 || std::strcmp( kind, "rest_pattern" ) == 0 )
        {
            ChildCursor cursor( node );
            std::vector<TSNode> children;
            collectChildren( node, cursor.cur, children );
            for( TSNode child : children ) { pending.push_back( child ); }
        }
    }
    std::sort( names.begin(), names.end() );
    names.erase( std::unique( names.begin(), names.end() ), names.end() );
    return names;
}

// The (EXPORTED name, LOCAL name) pairs a `export { f }` / `export { f as g }` clause binds — the clause
// form of an export, whose target may be declared anywhere in the file. Empty, deliberately, for the two
// shapes this table must NOT claim to know: a RE-EXPORT (`export { f } from './m.js'`, whose definition is
// in a third file), and `export type { F }` (which binds no value and must never mint a call edge). An
// empty result leaves the name UNLISTED, which buildJsImportTables degrades to the name ladder.
inline std::vector<std::pair<std::string, std::string>> jsExportClauseNames( TSNode stmt, std::string_view src )
{
    std::vector<std::pair<std::string, std::string>> names;
    if( !ts_node_is_null( ts_node_child_by_field_name( stmt, "source", 6 ) ) || jsHasToken( stmt, "type" ) )
    {
        return names;
    }
    std::vector<TSNode> pending{ stmt };
    while( !pending.empty() )
    {
        TSNode node = pending.back();
        pending.pop_back();
        if( jsNodeIs( node, "export_specifier" ) )
        {
            TSNode local = ts_node_child_by_field_name( node, "name", 4 );
            TSNode alias = ts_node_child_by_field_name( node, "alias", 5 );
            if( ts_node_is_null( alias ) ) { alias = local; }
            if( jsNodeIs( local, "identifier" ) && jsNodeIs( alias, "identifier" ) && !jsHasToken( node, "type" ) )
            {
                names.emplace_back( std::string( pattern::nodeText( alias, src ) ), std::string( pattern::nodeText( local, src ) ) );
            }
        }
        else if( jsNodeIs( node, "export_statement" ) || jsNodeIs( node, "export_clause" ) )
        {
            ChildCursor cursor( node );
            std::vector<TSNode> nested;
            collectChildren( node, cursor.cur, nested );
            for( TSNode child : nested ) { pending.push_back( child ); }
        }
    }
    return names;
}

inline void captureJsImportFacts( TSNode root, Lang lang, std::uint32_t fileId, std::string_view src, std::vector<RawBind>& binds )
{
    if( lang != Lang::TypeScript && lang != Lang::JavaScript ) { return; }
    ChildCursor cursor( root );
    std::vector<TSNode> children;
    collectChildren( root, cursor.cur, children );
    HashMap<std::string, char> imported;
    imported.reserve( children.size() );
    const auto record = [ & ]( TSNode node, LocalBindKind kind, std::string name, TSNode scope )
    {
        RawBind bind;
        bind.fileId = fileId;
        bind.lang = lang;
        bind.startByte = ts_node_start_byte( node );
        bind.kind = kind;
        bind.var = std::move( name );
        if( !ts_node_is_null( scope ) )
        {
            bind.spanStart = ts_node_start_byte( scope );
            bind.spanEnd = ts_node_end_byte( scope );
        }
        binds.push_back( std::move( bind ) );
    };
    for( TSNode stmt : children )
    {
        if( jsNodeIs( stmt, "import_statement" ) )
        {
            TSNode source = ts_node_child_by_field_name( stmt, "source", 6 );
            if( ts_node_is_null( source ) ) { continue; }
            const std::string module = importSpecifierText( source, src );
            std::vector<TSNode> pending{ stmt };
            while( !pending.empty() )
            {
                TSNode node = pending.back();
                pending.pop_back();
                if( jsNodeIs( node, "import_specifier" ) )
                {
                    TSNode name = ts_node_child_by_field_name( node, "name", 4 );
                    TSNode alias = ts_node_child_by_field_name( node, "alias", 5 );
                    if( ts_node_is_null( alias ) ) { alias = name; }
                    if( !jsNodeIs( alias, "identifier" ) ) { continue; }
                    std::string local( pattern::nodeText( alias, src ) );
                    imported.try_emplace( local, 1 );
                    record( stmt, LocalBindKind::JsImport, std::move( local ), {} );
                    binds.back().typeName = module;
                    if( !jsHasToken( stmt, "type" ) && !jsHasToken( node, "type" ) && jsNodeIs( name, "identifier" ) )
                    {
                        binds.back().importedName = std::string( pattern::nodeText( name, src ) );
                    }
                }
                else if( jsNodeIs( node, "import_statement" ) || jsNodeIs( node, "import_clause" ) || jsNodeIs( node, "named_imports" ) )
                {
                    ChildCursor childCursor( node );
                    std::vector<TSNode> nested;
                    collectChildren( node, childCursor.cur, nested );
                    for( TSNode child : nested ) { pending.push_back( child ); }
                }
            }
        }
        else if( jsNodeIs( stmt, "export_statement" ) && !jsHasToken( stmt, "default" ) )
        {
            TSNode decl = ts_node_child_by_field_name( stmt, "declaration", 11 );
            if( ts_node_is_null( decl ) )
            {
                // Clause form. The scope is the whole PROGRAM: a clause exports a module-scope binding and
                // the declaration it names may sit anywhere in the file (hoisted, or simply above).
                // importedName is spelled even when it equals `var` — it is what buildJsImportTables matches
                // a DEFINITION by, and it is what keeps two specifiers of one clause (which share this
                // statement's start byte) distinguishable to emitBindings' total order.
                for( const auto& [ exportName, localName ] : jsExportClauseNames( stmt, src ) )
                {
                    record( stmt, LocalBindKind::JsExport, exportName, root );
                    binds.back().importedName = localName;
                }
                continue;
            }
            TSNode name = ts_node_child_by_field_name( decl, "name", 4 );
            if( jsNodeIs( decl, "function_declaration" ) || jsNodeIs( decl, "generator_function_declaration" )
                || jsNodeIs( decl, "class_declaration" ) || jsNodeIs( decl, "abstract_class_declaration" ) )
            {
                record( stmt, LocalBindKind::JsExport, std::string( pattern::nodeText( name, src ) ), decl );
            }
            else if( jsNodeIs( decl, "lexical_declaration" ) || jsNodeIs( decl, "variable_declaration" ) )
            {
                ChildCursor declCursor( decl );
                std::vector<TSNode> declarators;
                collectChildren( decl, declCursor.cur, declarators );
                for( TSNode variable : declarators )
                {
                    if( !jsNodeIs( variable, "variable_declarator" ) ) { continue; }
                    TSNode value = ts_node_child_by_field_name( variable, "value", 5 );
                    if( !jsNodeIs( value, "arrow_function" ) && !jsNodeIs( value, "function_expression" ) ) { continue; }
                    TSNode binding = ts_node_child_by_field_name( variable, "name", 4 );
                    if( jsNodeIs( binding, "identifier" ) )
                    {
                        record( stmt, LocalBindKind::JsExport, std::string( pattern::nodeText( binding, src ) ), decl );
                    }
                }
            }
        }
    }
    if( imported.empty() ) { return; }

    // Imports are module-scoped. Record matching declarations' lexical spans so nested closures inherit
    // shadows too. We deliberately omit local-call inference here; a shadow may resolve to no edge.
    std::vector<TSNode> pending{ root };
    while( !pending.empty() )
    {
        TSNode node = pending.back();
        pending.pop_back();
        TSNode binding{};
        TSNode scope{};
        if( jsFunctionScope( node ) )
        {
            binding = ts_node_child_by_field_name( node, "parameters", 10 );
            if( ts_node_is_null( binding ) ) { binding = ts_node_child_by_field_name( node, "parameter", 9 ); }
            scope = node;
        }
        else if( jsNodeIs( node, "catch_clause" ) )
        {
            binding = ts_node_child_by_field_name( node, "parameter", 9 );
            scope = node;
        }
        else if( jsNodeIs( node, "for_in_statement" ) )
        {
            binding = ts_node_child_by_field_name( node, "left", 4 );
            scope = node;
            if( jsHasToken( node, "var" ) )
            {
                for( scope = ts_node_parent( node ); !ts_node_is_null( scope ); scope = ts_node_parent( scope ) )
                {
                    if( jsFunctionScope( scope ) || jsNodeIs( scope, "program" ) ) { break; }
                }
            }
        }
        else if( jsNodeIs( node, "variable_declarator" ) )
        {
            binding = ts_node_child_by_field_name( node, "name", 4 );
            const bool isVar = jsNodeIs( ts_node_parent( node ), "variable_declaration" );
            for( scope = ts_node_parent( node ); !ts_node_is_null( scope ); scope = ts_node_parent( scope ) )
            {
                if( jsFunctionScope( scope ) || jsNodeIs( scope, "program" )
                    || ( !isVar && ( jsNodeIs( scope, "statement_block" ) || jsNodeIs( scope, "for_statement" )
                                    || jsNodeIs( scope, "for_in_statement" ) || jsNodeIs( scope, "switch_body" ) ) ) ) { break; }
            }
        }
        if( ( jsNodeIs( node, "variable_declarator" ) || jsNodeIs( node, "for_in_statement" ) )
            && !ts_node_is_null( scope ) && jsFunctionScope( scope ) )
        {
            scope = ts_node_child_by_field_name( scope, "body", 4 );
        }
        for( std::string name : jsPatternNames( binding, src ) )
        {
            if( imported.find( name ) != imported.end() ) { record( node, LocalBindKind::JsShadow, std::move( name ), scope ); }
        }
        // Hoisted local function/class declarations also hide imports, independently of their parameters.
        if( jsNodeIs( node, "function_declaration" ) || jsNodeIs( node, "generator_function_declaration" ) || jsNodeIs( node, "class_declaration" )
            || jsNodeIs( node, "function_expression" ) || jsNodeIs( node, "generator_function" ) || jsNodeIs( node, "class" )
            || jsNodeIs( node, "abstract_class_declaration" ) )
        {
            TSNode nameNode = ts_node_child_by_field_name( node, "name", 4 );
            if( !ts_node_is_null( nameNode ) )
            {
                std::string name( pattern::nodeText( nameNode, src ) );
                if( imported.find( name ) != imported.end() )
                {
                    const bool expression = jsNodeIs( node, "function_expression" ) || jsNodeIs( node, "generator_function" ) || jsNodeIs( node, "class" );
                    TSNode parent = expression ? node : ts_node_parent( node );
                    while( !expression && !ts_node_is_null( parent ) && !jsNodeIs( parent, "statement_block" ) && !jsNodeIs( parent, "program" ) )
                    { parent = ts_node_parent( parent ); }
                    record( node, LocalBindKind::JsShadow, std::move( name ), parent );
                }
            }
        }
        ChildCursor childCursor( node );
        std::vector<TSNode> nested;
        collectChildren( node, childCursor.cur, nested );
        for( TSNode child : nested ) { pending.push_back( child ); }
    }
}

} // namespace
} // namespace rw
