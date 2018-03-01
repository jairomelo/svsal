xquery version "3.0";

(:~
 : A set of helper functions to access the application context from
 : within a module.
 :)
module namespace config = "http://xtriples.spatialhumanities.de/config";

import module namespace console = "http://exist-db.org/xquery/console";
declare namespace request       = "http://exist-db.org/xquery/request";
declare namespace system        = "http://exist-db.org/xquery/system";
declare namespace templates     = "http://exist-db.org/xquery/templates";
declare namespace repo          = "http://exist-db.org/xquery/repo";
declare namespace expath        = "http://expath.org/ns/pkg";

(: default service locations
declare variable $config:xtriplesWebserviceURL := "http://xtriples.spatialhumanities.de/";
declare variable $config:any23WebserviceURL := "http://any23-vm.apache.org/";
:)

(: --- SvSal customizations: service locations, debugging level etc. --- :)
declare variable $config:xtriplesWebserviceURL     := "http://api.salamanca.school/lod";
declare variable $config:any23WebserviceURL        := "http://localhost:8880/any23/any23/";
declare variable $config:debug                     := "info"; (: possible values: trace, info, none :)
declare variable $config:logfile                   := "xTriples.log";

(: Configure Servers :)
declare variable $config:proto          := if (request:get-header('X-Forwarded-Proto') = "https") then "https" else request:get-scheme();
declare variable $config:subdomains     := ("www", "blog", "facs", "search", "data", "api", "tei", "id", "files", "ldf", "software");
declare variable $config:serverdomain := 
    if (substring-before(request:get-header('X-Forwarded-Host'), ".") = $config:subdomains)
        then substring-after(request:get-header('X-Forwarded-Host'), ".")
    else if(request:get-header('X-Forwarded-Host'))
        then request:get-header('X-Forwarded-Host')
    else if(substring-before(request:get-server-name(), ".") = $config:subdomains)
        then substring-after(request:get-server-name(), ".")
    else
        let $alert := if ($config:debug = "trace") then console:log("Warning! Dynamic $config:serverdomain is uncertain, using servername " || request:get-server-name() || ".") else ()
        return request:get-server-name()
    ;
declare variable $config:idserver       := $config:proto || "://id."     || $config:serverdomain;

(: --- SvSal customizations end --- :)

declare variable $config:redeferWebserviceURL      := "http://rhizomik.net/redefer-services/";
declare variable $config:redeferWebserviceRulesURL := "http://rhizomik.net:8080/html/redefer/rdf2svg/showgraph.jrule";

(: 
    Determine the application root collection from the current module load path.
:)
declare variable $config:app-root := 
    let $rawPath := system:get-module-load-path()
    let $modulePath :=
        (: strip the xmldb: part :)
        if (starts-with($rawPath, "xmldb:exist://")) then
            if (starts-with($rawPath, "xmldb:exist://embedded-eXist-server")) then
                substring($rawPath, 36)
            else
                substring($rawPath, 15)
        else
            $rawPath
    return
        substring-before($modulePath, "/modules")
;

declare variable $config:data-root := $config:app-root || "/data";
declare variable $config:repo-descriptor := doc(concat($config:app-root, "/repo.xml"))/repo:meta;
declare variable $config:expath-descriptor := doc(concat($config:app-root, "/expath-pkg.xml"))/expath:package;

(:~
 : Resolve the given path using the current application context.
 : If the app resides in the file system,
 :)
declare function config:resolve($relPath as xs:string) {
    if (starts-with($config:app-root, "/db")) then
        doc(concat($config:app-root, "/", $relPath))
    else
        doc(concat("file://", $config:app-root, "/", $relPath))
};

(:~
 : Returns the repo.xml descriptor for the current application.
 :)
declare function config:repo-descriptor() as element(repo:meta) {
    $config:repo-descriptor
};

(:~
 : Returns the expath-pkg.xml descriptor for the current application.
 :)
declare function config:expath-descriptor() as element(expath:package) {
    $config:expath-descriptor
};

declare %templates:wrap function config:app-title($node as node(), $model as map(*)) as text() {
    $config:expath-descriptor/expath:title/text()
};

declare function config:app-meta($node as node(), $model as map(*)) as element()* {
    <meta xmlns="http://www.w3.org/1999/xhtml" name="description" content="{$config:repo-descriptor/repo:description/text()}"/>,
    for $author in $config:repo-descriptor/repo:author
    return
        <meta xmlns="http://www.w3.org/1999/xhtml" name="creator" content="{$author/text()}"/>
};

(:~
 : For debugging: generates a table showing all properties defined
 : in the application descriptors.
 :)
declare function config:app-info($node as node(), $model as map(*)) {
    let $expath := config:expath-descriptor()
    let $repo := config:repo-descriptor()
    return
        <table class="app-info">
            <tr>
                <td>app collection:</td>
                <td>{$config:app-root}</td>
            </tr>
            {
                for $attr in ($expath/@*, $expath/*, $repo/*)
                return
                    <tr>
                        <td>{node-name($attr)}:</td>
                        <td>{$attr/string()}</td>
                    </tr>
            }
            <tr>
                <td>Controller:</td>
                <td>{ request:get-attribute("$exist:controller") }</td>
            </tr>
        </table>
};