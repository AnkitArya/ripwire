#pragma once
#if !defined( RIPWIRE_INGEST_TU )
#error "ingest_jsimports.h belongs only to ingest.cpp"
#endif

namespace rw
{
namespace
{

// ES named imports carry three independent facts: local spelling, export spelling, and module.
// Only direct exported declarations are resolved. Barrels and type-only imports remain known gaps.
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
            if( ts_node_is_null( decl ) ) { continue; }
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
