xquery version "3.0";

module namespace sphinx            = "http://salamanca/sphinx";
declare namespace sphinxNS         = "http://sphinxsearch.com";
declare namespace tei              = "http://www.tei-c.org/ns/1.0";
declare namespace sal              = "http://salamanca.adwmainz.de";
declare namespace opensearch       = "http://a9.com/-/spec/opensearch/1.1/";
declare namespace templates        = "http://exist-db.org/xquery/templates";
import module namespace functx     = "http://www.functx.com";
import module namespace app        = "http://salamanca/app"     at "app.xql";
import module namespace config     = "http://salamanca/config"  at "config.xqm";
import module namespace render     = "http://salamanca/render"  at "render.xql";
import module namespace console    = "http://exist-db.org/xquery/console";
import module namespace http       = "http://expath.org/ns/http-client";
import module namespace httpclient = "http://exist-db.org/xquery/httpclient";
import module namespace i18n       = "http://exist-db.org/xquery/i18n";
import module namespace util       = "http://exist-db.org/xquery/util";
import module namespace xmldb      = "http://exist-db.org/xquery/xmldb";

declare copy-namespaces no-preserve, inherit;

declare namespace output = "http://www.w3.org/2010/xslt-xquery-serialization";
declare option    output:method "xml";

(: REST endpoints for Sphinx based Salamanca index:

Perform search request [GET] - http://search.salamanca.school/lemmatized/search
Extract keywords from query [GET] - http://search.salamanca.school/lemmatized/keywords
Hightlight given snippets [POST] - http://search.salamanca.school/lemmatized/excerpts

Response format is Open Search based XML - @see http://www.opensearch.org/Home and http://search.salamanca.school/lemmatized
:)

declare variable $sphinx:schema  :=
    <sphinx:schema>
        <sphinx:attr  name="sphinx_docid"           type="int" />
        <sphinx:attr  name="sphinx_work"            type="string" />
        <sphinx:attr  name="sphinx_work_type"       type="string" />
        <sphinx:attr  name="sphinx_author"          type="string" />
        <sphinx:attr  name="sphinx_authorid"        type="string" />
        <sphinx:attr  name="sphinx_title"           type="string" />
        <sphinx:attr  name="sphinx_year"            type="string" />
        <sphinx:attr  name="sphinx_hit_type"        type="string" />
        <sphinx:attr  name="sphinx_hit_id"          type="string" />
        <sphinx:attr  name="sphinx_hit_language"    type="string" />
        <sphinx:attr  name="sphinx_html_path"       type="string" />
        <sphinx:attr  name="sphinx_fragment_path"   type="string" />
        <sphinx:attr  name="sphinx_fragment_number" type="int" />

        <sphinx:field  name="sphinx_work"            type="string" />
        <sphinx:field  name="sphinx_work_type"       type="string" />
        <sphinx:field  name="sphinx_author"          type="string" />
        <sphinx:field  name="sphinx_authorid"        type="string" />
        <sphinx:field  name="sphinx_title"           type="string" />
        <sphinx:field  name="sphinx_year"            type="string" />
        <sphinx:field  name="sphinx_hit_type"        type="string" />
        <sphinx:field  name="sphinx_hit_id"          type="string" />
        <sphinx:field  name="sphinx_hit_language"    type="string" />

        <sphinx:field   name="sphinx_description_orig"  attr="string" />
        <sphinx:field   name="sphinx_description_edit"  attr="string" />
    </sphinx:schema>;

(: ####====---- Helper Functions ----====#### :)

declare function sphinx:needsSnippets($targetWorkId as xs:string) as xs:boolean {
    let $targetSubcollection := for $subcollection in $config:tei-sub-roots return 
                                    if (doc-available(concat($subcollection, '/', $targetWorkId, '.xml'))) then $subcollection
                                    else ()
    let $targetWorkModTime := xmldb:last-modified($targetSubcollection, $targetWorkId || '.xml')
(:    let $newestSnippet := max(for $file in xmldb:get-child-resources($config:snippets-root || '/' || $targetWorkId) return xmldb:last-modified($config:snippets-root || '/' || $targetWorkId, $file)):)

    return if (xmldb:collection-available($config:snippets-root || '/' || $targetWorkId)) then
                let $snippetsModTime := max(for $file in xmldb:get-child-resources($config:snippets-root || '/' || $targetWorkId) return xmldb:last-modified($config:snippets-root || '/' || $targetWorkId, $file))
                return if ($snippetsModTime lt $targetWorkModTime) then true() else false()
        else
            true()
};

declare function sphinx:needsSnippetsString($node as node(), $model as map(*)) {
    let $currentWorkId := max((string($model('currentWork')/@xml:id), string($model('currentAuthor')/@xml:id), string($model('currentLemma')/@xml:id), string($model('currentWp')/@xml:id)))
    let $targetSubcollection := for $subcollection in $config:tei-sub-roots return 
                                    if (doc-available(concat($subcollection, '/', $currentWorkId, '.xml'))) then $subcollection
                                    else ()
    return if (sphinx:needsSnippets($currentWorkId)) then
                    <td title="{concat(if (xmldb:collection-available($config:snippets-root || '/' || $currentWorkId)) then concat('Snippets created on: ', max(for $file in xmldb:get-child-resources($config:snippets-root || '/' || $currentWorkId) return string(xmldb:last-modified($config:snippets-root || '/' || $currentWorkId, $file))), ', ') else (), 'Source from: ', string(xmldb:last-modified($targetSubcollection, $currentWorkId || '.xml')), '.')}"><a href="sphinx-admin.xql?wid={$currentWorkId}"><b>Create snippets NOW!</b></a></td>
            else
                    <td title="{concat('Snippets created on: ', max(for $file in xmldb:get-child-resources($config:snippets-root || '/' || $currentWorkId) return string(xmldb:last-modified($config:snippets-root || '/' || $currentWorkId, $file))), ', Source from: ', string(xmldb:last-modified($targetSubcollection, $currentWorkId || '.xml')), '.')}">Creating snippets unnecessary. <small><a href="sphinx-admin.xql?wid={$currentWorkId}">Create snippets anyway!</a></small></td>
};

declare function sphinx:passLang($node as node(), $model as map(*)) {
    <input type="hidden" name="lang" value="{request:get-parameter('lang', 'en')}"/>
};

(: ####====---- End Helper Functions ----====#### :)

declare function sphinx:buildSelect ($node as node(), $model as map(*), $lang as xs:string?) {
    let $string1 := i18n:process(<i18n:text key='everythingDesc'>Suche in Werken, Personen- und Sachwörterbuch-Artikeln sowie in Abstracts und Keywords der Working Papers.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")
    let $string2 := i18n:process(<i18n:text key='corpusDesc'>Suche im kompletten Text der Werke.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")
    let $string3 := i18n:process(<i18n:text key='headingsDesc'>Suche nur in den Überschriften der Werke.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")
    let $string4 := i18n:process(<i18n:text key='notesDesc'>Suche nur in den Marginal-, Fuß- und Endnoten der Werke.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")
    let $string5 := i18n:process(<i18n:text key='nonotesDesc'>Suche in Werken, aber nicht in den Marginal-, Fuß- und Endnoten.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")
    let $string8 := i18n:process(<i18n:text key='dictDesc'>Suche im Volltext aller Einträge des Wörterbuchs.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")
    let $string9 := i18n:process(<i18n:text key='entriesDesc'>Suche in Titeln und Überschriften von Wörterbuchartikeln.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")
    let $stringA := i18n:process(<i18n:text key='wpDesc'>Suche in Abstacts und Metadaten unserer Working Papers.</i18n:text>,
                                 $lang,
                                 "/db/apps/salamanca/data/i18n",
                                 "en")

(: To be included in $output once the dictionary is available:         
            <option value="dict" accesskey="8" title="{$string8}">
                <i18n:text key="dictionary">Wörterbucheinträge</i18n:text>: <i18n:text key="fulltext">Volltext</i18n:text>
            </option>
            <option value="entries" accesskey="9" title="{$string9}">
                <i18n:text key="dictionary">Wörterbucheinträge</i18n:text>: <i18n:text key="headings">Überschriften</i18n:text>
            </option>                               :)
    let $output :=
        <select name="field" data-template="form-control" class="span12 form-control templates:form-control">
            <option value="everything" accesskey="1" title="{$string1}">
                <i18n:text key="global">Alle Datenquellen</i18n:text>
            </option>
            <option value="corpus" accesskey="2" title="{$string2}">
                <i18n:text key="corpus">Werke</i18n:text>: <i18n:text key="fulltext">Volltext</i18n:text>
            </option>
            <option value="headings" accesskey="3" title="{$string3}">
                <i18n:text key="corpus">Werke</i18n:text>: <i18n:text key="headings">Überschriften</i18n:text>
            </option>
            <option value="notes" accesskey="4" title="{$string4}">
                <i18n:text key="corpus">Werke</i18n:text>: <i18n:text key="notes">Noten</i18n:text>
            </option>
            <option value="nonotes" accesskey="5" title="{$string4}">
                <i18n:text key="corpus">Werke</i18n:text>: <i18n:text key="nonotes">ohne Noten</i18n:text>
            </option>
            <option value="wp" accesskey="a" title="{$stringA}">
                <i18n:text key="workingPapers">Working Papers</i18n:text>: <i18n:text key="WPMetadata">Abstract und Metadaten</i18n:text>
            </option>
        </select>
    return i18n:process($output, $lang, "/db/apps/salamanca/data/i18n", session:encode-url(request:get-uri()))
};

declare %public
    %templates:wrap
    %templates:default ("field",  "everything")
    %templates:default ("offset", "0")
    %templates:default ("limit",  "10")
function sphinx:search ($context as node()*, $model as map(*), $q as xs:string?, $field as xs:string, $offset as xs:integer, $limit as xs:integer) {
    if ($q) then
        let $searchRequestHeaders   := <headers></headers>
        let $hits :=

(: **** Case 1: Search "everything" **** 
   **** We do several searches, showing the top 5 results in each category
:)
            if ($field eq 'everything') then
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $groupingParameters         := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters           := "&amp;offset=" || $offset || "&amp;limit=" || $config:searchMultiModeLimit
                let $searchRequestWorks         := concat($config:sphinxRESTURL, "/search?q=", "%40%28sphinx_author%2Csphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), '%20%40sphinx_work%20%5EW0%2A%20', $groupingParameters, $pagingParameters)
                let $searchRequestDictEntries   := concat($config:sphinxRESTURL, "/search?q=", "%40%28sphinx_author%2Csphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), '%20%40sphinx_work%20%5EL%2A%20',  $groupingParameters, $pagingParameters)
                let $searchRequestWorkingPapers := concat($config:sphinxRESTURL, "/search?q=", "%40%28sphinx_author%2Csphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), '%20%40sphinx_work%20%5EWP%2A%20', $groupingParameters, $pagingParameters)

                let $debug1 := if ($config:debug = "trace") then console:log("Search Request for " || $q || " in Works: " || $searchRequestWorks || ".") else ()
                let $debug2 := if ($config:debug = "trace") then console:log("Search Request for " || $q || " in Dict: "  || $searchRequestDictEntries || ".") else ()
                let $debug3 := if ($config:debug = "trace") then console:log("Search Request for " || $q || " in WPs: "   || $searchRequestWorkingPapers || ".") else ()

                let $topWorks                   := httpclient:get($searchRequestWorks,          false(), $searchRequestHeaders)
                let $topDictEntries             := httpclient:get($searchRequestDictEntries,    false(), $searchRequestHeaders)
                let $topWorkingPapers           := httpclient:get($searchRequestWorkingPapers,  false(), $searchRequestHeaders)
                let $debug4 :=  if ($config:debug = "trace") then
                                    (console:log("Search requests returned " || count($topWorks//item) || "/" || count($topDictEntries//item) || "/" || count($topWorkingPapers//item) || " results:"),
                                     console:log("Response for Works Query: " || serialize($topWorks)),
                                     console:log("Response for Dict Query: "  || serialize($topDictEntries)),
                                     console:log("Response for WP Query: "    || serialize($topWorkingPapers))
                                    )
                                else ()
                return <sal:results>
                            <sal:works>{$topWorks//httpclient:body/rss}</sal:works>
                            <sal:dictEntries>{$topDictEntries//httpclient:body/rss}</sal:dictEntries>
                            <sal:workingPapers>{$topWorkingPapers//httpclient:body/rss}</sal:workingPapers>
                       </sal:results>

(: **** Case 2: Search "corpus" **** 
   **** We do a full corpus search, grouping results by work id.
:)
            else if ($field eq 'corpus') then                                                           (:   Work-Type      +   hit-type               +        Fulltext fields                   have         query term :)
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EW0%2A"
                let $addConditionParameters  := ""
                let $alsoSearchAuthorField   := "sphinx_author%2C"
                let $groupingParameters      := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss

(: **** Case 2a: Search "corpus-nogroup" **** 
   **** We do a full corpus search, without grouping results.
:)
            else if ($field eq 'corpus-nogroup') then                                                           (:   Work-Type      +   hit-type               +        Fulltext fields                   have         query term :)
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EW0%2A"
                let $addConditionParameters  := ""
                let $alsoSearchAuthorField   := "sphinx_author%2C"
                let $groupingParameters      := ""
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss

(:  **** Case 3: Search "headings" **** 
    **** We do a full corpus search, with the additional condition that "@sphinx_hit_type head titlePart", grouping results by work id.
:)
            else if ($field eq 'headings') then
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                filter also by hit type,
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EW0%2A%20"
                let $addConditionParameters  := "%20%40sphinx_hit_type%20%3Dhead%20%7C%20%3DtitlePage"
                let $alsoSearchAuthorField   := ""
                let $groupingParameters      := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss
(:  **** Case 4: Search "notes" **** 
    **** We do a full corpus search, with the additional condition that "@sphinx_hit_type note", grouping results by work id.
:)
            else if ($field eq 'notes') then
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                filter also by hit type,
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EW0%2A%20"
                let $addConditionParameters  := "%20%40sphinx_hit_type%20%3Dnote"
                let $alsoSearchAuthorField   := ""
                let $groupingParameters      := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss

(:  **** Case 5: Search "nonotes" **** 
    **** We do a full corpus search, with the additional condition that "@sphinx_hit_type != note", grouping results by work id.
:)
            else if ($field eq 'nonotes') then
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                filter also by hit type,
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EW0%2A%20"
                let $addConditionParameters  := "%20%40sphinx_hit_type%20%3D%21note"
                let $alsoSearchAuthorField   := ""
                let $groupingParameters      := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss

(:  **** Cases that we don't even have yet **** 
            else if ($field eq 'persons') then
                let $pagingParameters       := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest  := concat($config:sphinxRESTURL, "/search?q=", concat('%40%28sphinx_author%2Csphinx_description_edit%2Csphinx_description_orig%29%20', encode-for-uri($q), '%20%40sphinx_hit_type%20persName%20%40sphinx_work%20%5EW0%2A%20'), $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss
            else if ($field eq 'places') then
                let $pagingParameters       := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest  := concat($config:sphinxRESTURL, "/search?q=", concat('%40%28sphinx_author%2Csphinx_description_edit%2Csphinx_description_orig%29%20', encode-for-uri($q), '%20%40sphinx_hit_type%20placeName%20%40sphinx_work%20%5EW0%2A%20'), $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss
            else if ($field eq 'lemmata') then
                let $pagingParameters       := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest  := concat($config:sphinxRESTURL, "/search?q=", concat('%40%28sphinx_author%2Csphinx_description_edit%2Csphinx_description_orig%29%20', encode-for-uri($q), '%20%40sphinx_hit_type%20term%20%40sphinx_work%20%5EW0%2A%20'), $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss
:)

(:  **** Case 8: Search "dict" (in dictionary) ****
    **** We do a full search on all @sphinx_work ^L* 
:)
            else if ($field eq 'dict') then                                                     (: Lemmata-Articles :)
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EL%2A%20"
                let $addConditionParameters  := ""
                let $alsoSearchAuthorField   := "sphinx_author%2C"
                let $groupingParameters      := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss

(:  **** Case 9: Search "entries" (i.e. in dictionary headings) ****
    **** We do a full search on all @sphinx_work ^L* with the additional condition that @sphinx_hit_type be 'head'
:)
            else if ($field eq 'entries') then
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                filter also by hit type,
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EL%2A%20"
                let $addConditionParameters  := "%20%40sphinx_hit_type%20%3Dhead"
                let $alsoSearchAuthorField   := ""
                let $groupingParameters      := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss

(:  **** Case A: Search "wp" ****
    **** We do a full search on all @sphinx_work ^WP* 
:)
            else if ($field eq 'wp') then                                                     (: Working Papers :)
            (: search for queryterm in sphinx_description_edit and ..._orig fields,
                filter by work type (for now, based on  work id, as of late we also have a work_type attritute that we should start using),
                filter also by hit type,
                group by work (so we don't the same document repeatedly),
                paginate results if necessary
            :)
                let $modeConditionParameters := "%20%40sphinx_work%20%5EWP%2A%20"
                let $addConditionParameters  := ""
                let $alsoSearchAuthorField   := "sphinx_author%2C"
                let $groupingParameters      := "&amp;groupby=sphinx_work&amp;groupfunc=4"
                let $pagingParameters        := "&amp;offset=" || $offset || "&amp;limit=" || $limit
                let $searchRequest           := concat($config:sphinxRESTURL, "/search?q=", "%40%28", $alsoSearchAuthorField, "sphinx_description_edit%2Csphinx_description_orig%29%20", encode-for-uri($q), $addConditionParameters, $modeConditionParameters, $groupingParameters, $pagingParameters)
                return httpclient:get($searchRequest, false(), $searchRequestHeaders)//httpclient:body/rss

            else()
        return map { "results" := $hits }
    else ()
};

declare 
    %templates:default ("offset", "0")
    %templates:default ("limit", "10")
function sphinx:resultsLandingPage ($node as node(), $model as map(*), $q as xs:string?,  $field as xs:string?, $offset as xs:integer?, $limit as xs:integer?, $sort as xs:integer?, $sortby as xs:string?, $lang as xs:string) {

    let $results  := $model("results")

(:  **** CASE 1: Search was after "everything". ****
    **** We show the top 5 results in each category,
    **** along with an "all..." button that switches to a dedicated corpus search.
:)
    let $output := if ($field eq "everything") then
        let $searchInfo := <p id="searchInfo"><i18n:text key="searchFor">Search for</i18n:text>: {string-join($results/sal:works//word, ', ')}</p>

        (: Get Works ... :)
        let $worksLink :=           if (xs:integer($results/sal:works//opensearch:totalResults/text()) > $config:searchMultiModeLimit ) then
                                        <span style="margin-left:7px;"><a href="search.html?field=corpus&amp;q={encode-for-uri($q)}&amp;offset=0&amp;limit={$limit}"><i18n:text key="allResults">Alle</i18n:text>...</a></span>
                                    else ()
        let $worksList :=           <div class="resultsSection">
                                          <h4><i18n:text key="works">Werke</i18n:text> ({$results/sal:works//opensearch:totalResults/text()})</h4>
                                          <ol class="resultsList">{
                                                for $item at $index in $results/sal:works//item
                                                    let $author         := $item/author/text()
                                                    let $title          := $item/title/text()
                                                    let $wid            := $item/work/text()
                                                    let $numberOfHits   := $item/sphinxNS:groupcount/text()
                                                    let $link           :=  if (contains($item/fragment_path/text(), "#")) then
                                                                                replace($item/fragment_path/text(), '#', '&amp;q=' || encode-for-uri($q) || '#')
                                                                            else if (contains($item/fragment_path/text(), "?")) then
                                                                                $item/fragment_path/text() || '&amp;q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                                                            else
                                                                                $item/fragment_path/text() || '?q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                                    let $detailsLink    := <a class="toggleDetails" href="#details_{$wid}" data-target="#details_{$wid}" data-toggle="collapse">{$numberOfHits}&#xA0;<i18n:text key="hits">Fundstellen</i18n:text>&#xA0;<i class="fa fa-chevron-down"aria-hidden="true"></i></a>
                                                    let $detailHTML     := sphinx:details($wid, $field, $q, 0, 10, $lang)

                                                    return 
                                                            <li class="lead">
                                                                <a href="{$link}">{$author}: {$title}</a><br/>
                                                                {$detailsLink}
                                                                <div id="details_{$wid}" class="collapse resultsDetails">{$detailHTML}</div>
                                                            </li>
                                          }</ol>
                                          {$worksLink}
                                      </div>

        (: Get Dictionary Entries ... :)
(:        let $dictEntriesLink :=     if (xs:integer($results/sal:dictEntries//opensearch:totalResults/text()) > $config:searchMultiModeLimit ) then
                                        <span style="margin-left:7px;"><a href="search.html?field=dict&amp;q={encode-for-uri($q)}&amp;offset=0&amp;limit={$limit}"><i18n:text key="allResults">all</i18n:text>...</a></span>
                                    else ()
        let $dictEntriesList :=     <div class="resultsSection">
                                        <h4><i18n:text key="dictionaryEntries">Wörterbucheinträge</i18n:text> ({$results/sal:dictEntries//opensearch:totalResults/text()})</h4>
                                        <ol class="resultsList">{
                                            for $item at $index in $results/sal:dictEntries//item
                                                let $author         := $item/author/text()
                                                let $title          := $item/title/text()
                                                let $wid            := $item/work/text()
                                                let $numberOfHits   := $item/sphinxNS:groupcount/text()
                                                let $link           :=  if (contains($item/fragment_path/text(), "#")) then
                                                                            replace($item/fragment_path/text(), '#', '&amp;q=' || encode-for-uri($q) || '#')
                                                                        else
                                                                            $item/fragment_path/text() || '&amp;q=' || encode-for-uri($q)    (\: this is the url to call the frg. in the webapp :\)
                                                let $detailsLink    := <a class="toggleDetails" href="#details_{$wid}" data-target="#details_{$wid}" data-toggle="collapse">{$numberOfHits}&#xA0;<i18n:text key="hits">Fundstellen</i18n:text>&#xA0;<i class="fa fa-chevron-down"aria-hidden="true"></i></a>
                                                let $detailHTML     := sphinx:details($wid, $field, $q, 0, 10, $lang)

                                                return 
                                                            <li class="lead">
                                                                <a href="{$link}">{$author}: {$title}</a><br/>
                                                                {$detailsLink}
                                                                <div id="details_{$wid}" class="collapse resultsDetails">{$detailHTML}</div>
                                                            </li>
                                        }</ol>
                                        {$dictEntriesLink}
                                    </div>:)

        (: Get Working Papers ... :)
        let $workingPapersLink :=   if (xs:integer($results/sal:workingPapers//opensearch:totalResults/text()) > $config:searchMultiModeLimit ) then
                                        <span style="margin-left:7px;"><a href="search.html?field=wp&amp;q={encode-for-uri($q)}&amp;offset=0&amp;limit={$limit}"><i18n:text key="allResults">all</i18n:text>...</a></span>
                                    else ()
        let $workingPapersList :=   <div class="resultsSection">
                                       <h4><i18n:text key="workingPapers">Working Papers</i18n:text> ({$results/sal:workingPapers//opensearch:totalResults/text()})</h4>
                                       <ol class="resultsList">{
                                            for $item at $index in $results/sal:workingPapers//item
                                                let $author         := $item/author/text()
                                                let $title          := $item/title/text()
                                                let $wid            := $item/work/text()
                                                let $numberOfHits   := $item/sphinxNS:groupcount/text()
                                                let $link           :=  if (contains($item/fragment_path/text(), "#")) then
                                                                            replace($item/fragment_path/text(), '#', '&amp;q=' || encode-for-uri($q) || '#')
                                                                        else if (contains($item/fragment_path/text(), "?")) then
                                                                            $item/fragment_path/text() || '&amp;q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                                                        else
                                                                            $item/fragment_path/text() || '?q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                                let $detailsLink    := <a class="toggleDetails" href="#details_{$wid}" data-target="#details_{$wid}" data-toggle="collapse">{$numberOfHits}&#xA0;<i18n:text key="hits">Fundstellen</i18n:text>&#xA0;<i class="fa fa-chevron-down"aria-hidden="true"></i></a>
                                                let $detailHTML     := sphinx:details($wid, $field, $q, 0, 10, $lang)

                                                return 
                                                            <li class="lead">
                                                                <a href="{$link}">{$author}: {$title}</a><br/>
                                                                {$detailsLink}
                                                                <div id="details_{$wid}" class="collapse resultsDetails">{$detailHTML}</div>
                                                            </li>
                                       }</ol>
                                       {$workingPapersLink}
                                   </div>
        
        (: include {$dictEntriesList} once the dictionary is available :)
        return
            <div class="searchResults">
                {$searchInfo}
                {$worksList}
                {$workingPapersList}
            </div>


(:  **** CASE 2: Search was after "corpus", "headings", "notes" or "nonotes" etc., i.e. in works. ****
    **** We show the paged results, grouped after work_id
    **** along with an "details" buttons that expand the tree structure of a single work
:)
    else if ($field = ("corpus", "headings", "notes", "nonotes")) then
        let $searchInfo :=  <p id="searchInfo"><i18n:text key="searchFor">Suche nach</i18n:text>: {string-join($results//word[not(. = ('notar', 'head', 'titlepage'))], ', ')}<br/>
                              <i18n:text key="found">Gefunden</i18n:text>:{$config:nbsp}<strong>{$results//opensearch:totalResults/text()}{$config:nbsp}<i18n:text key="works">Werke</i18n:text>.</strong>{$config:nbsp}
                              <i18n:text key="display">Anzeige</i18n:text>:{$config:nbsp}{xs:integer($offset) + 1}-{xs:integer($offset) + count($results//item)}
                            </p>
        let $prevPageLink := if (xs:integer($results//opensearch:startIndex/text()) > 1 ) then
                                <span><a href="search.html?field={$field}&amp;q={$q}&amp;offset={$offset - $limit}&amp;limit={$limit}"  class="prevnext_majorList"><i18n:text key="prev">Vorige</i18n:text> <i18n:text key="prev">Werke</i18n:text></a>{$config:nbsp || $config:nbsp}</span>
                             else ()
        let $nextPageLink := if (xs:integer($results//opensearch:startIndex/text())+xs:integer($results//opensearch:itemsPerPage/text())-1 lt xs:integer($results//opensearch:totalResults/text())) then
                                <a href="search.html?field={$field}&amp;q={$q}&amp;offset={$offset + $limit}&amp;limit={$limit}" class="prevnext_majorList"><i18n:text key="next">Nächste</i18n:text> <i18n:text key="prev">Werke</i18n:text></a>
                             else ()
        let $worksList :=   <ul class="resultsList">{
                                    for $item at $index in $results//item
                                        let $author         := $item/author/text()
                                        let $title          := $item/title/text()
                                        let $wid            := $item/work/text()
                                        let $numberOfHits   := $item/sphinxNS:groupcount/text()
                                        let $link           :=  if (contains($item/fragment_path/text(), "#")) then
                                                                    replace($item/fragment_path/text(), '#', '&amp;q=' || encode-for-uri($q) || '#')
                                                                else if (contains($item/fragment_path/text(), "?")) then
                                                                    $item/fragment_path/text() || '&amp;q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                                                else
                                                                    $item/fragment_path/text() || '?q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                        let $detailsLink    := <a class="toggleDetails" href="#details_{$wid}" data-target="#details_{$wid}" data-toggle="collapse">{$numberOfHits}&#xA0;<i18n:text key="hits">Fundstellen</i18n:text>&#xA0;<i class="fa fa-chevron-down"aria-hidden="true"></i></a>
                                        let $detailHTML     := sphinx:details($wid, $field, $q, 0, 10, $lang)
                                        return
                                            <li>
                                                <a href="{$link}">{$author}: {$title}</a><br/>
                                                {$detailsLink}
                                                <div id="details_{$wid}" class="collapse resultsDetails">{$detailHTML}</div>
                                            </li>
                                }</ul>
        return
            <div class="searchResults">
                {$searchInfo}
                <div>
                    {$prevPageLink, $nextPageLink}
                </div>
                <div class="resultsSection">
                    {$worksList}
                </div>
            </div>

(:  **** CASE 3: Search was after "dict" or "entries" etc., i.e. in dictionaries. ****
    **** We show the paged results, grouped after work_id
    **** along with an "details" buttons that expand the tree structure of a single work
:)
    else if ($field = ("dict", "entries")) then
        let $searchInfo :=  <p id="searchInfo"><i18n:text key="searchFor">Suche nach</i18n:text>: {string-join($results//word[not(string(.) eq 'head')], ', ')}<br/>
                              <i18n:text key="found">Gefunden</i18n:text>:{$config:nbsp}<strong>{$results//opensearch:totalResults/text()}{$config:nbsp}<i18n:text key="dictionaryEntries">Wörterbucheinträge</i18n:text>.</strong>{$config:nbsp}
                              <i18n:text key="display">Anzeige</i18n:text>:{$config:nbsp}{xs:integer($offset) + 1}-{xs:integer($offset) + count($results//item)}
                            </p>
        let $prevPageLink := if (xs:integer($results//opensearch:startIndex/text()) > 1 ) then
                                <span><a href="search.html?field={$field}&amp;q={$q}&amp;offset={$offset - $limit}&amp;limit={$limit}"  class="prevnext_majorList"><i18n:text key="prev">Vorige</i18n:text> <i18n:text key="prev">Werke</i18n:text></a>{$config:nbsp || $config:nbsp}</span>
                             else ()
        let $nextPageLink := if (xs:integer($results//opensearch:startIndex/text())+xs:integer($results//opensearch:itemsPerPage/text())-1 lt xs:integer($results//opensearch:totalResults/text())) then
                                <a href="search.html?field={$field}&amp;q={$q}&amp;offset={$offset + $limit}&amp;limit={$limit}" class="prevnext_majorList"><i18n:text key="next">Nächste</i18n:text> <i18n:text key="prev">Werke</i18n:text></a>
                             else ()
        let $entriesList :=  <ul class="resultsList">{
                                    for $item at $index in $results//item
                                        let $author         := $item/author/text()
                                        let $title          := $item/title/text()
                                        let $wid            := $item/work/text()
                                        let $numberOfHits   := $item/sphinxNS:groupcount/text()
                                        let $link           :=  if (contains($item/fragment_path/text(), "#")) then
                                                                    replace($item/fragment_path/text(), '#', '&amp;q=' || encode-for-uri($q) || '#')
                                                                else if (contains($item/fragment_path/text(), "?")) then
                                                                    $item/fragment_path/text() || '&amp;q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                                                else
                                                                    $item/fragment_path/text() || '?q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                        let $detailsLink    := <a class="toggleDetails" href="#details_{$wid}" data-target="#details_{$wid}" data-toggle="collapse">{$numberOfHits}&#xA0;<i18n:text key="hits">Fundstellen</i18n:text>&#xA0;<i class="fa fa-chevron-down"aria-hidden="true"></i></a>
                                        let $detailHTML     := sphinx:details($wid, $field, $q, 0, 10, $lang)
                                        return
                                            <li>
                                                <a href="{$link}">{$title} ({$author})</a><br/>
                                                {$detailsLink}
                                                <div id="details_{$wid}" class="collapse resultsDetails">{$detailHTML}</div>
                                            </li>
                                }</ul>
        return
            <div class="searchResults">
                {$searchInfo}
                <div>
                    {$prevPageLink, $nextPageLink}
                </div>
                <div class="resultsSection">
                    {$entriesList}
                </div>
            </div>


(:  **** CASE 4: Search was after "wp", i.e. after meta-information of working papers. ****
    **** We show the paged results, grouped after work_id
    **** along with an "details" buttons that expand the tree structure of a single work
:)
    else if ($field eq "wp") then
        let $searchInfo :=  <p id="searchInfo"><i18n:text key="searchFor">Suche nach</i18n:text>: {string-join($results//word, ', ')}<br/>
                              <i18n:text key="found">Gefunden</i18n:text>:{$config:nbsp}<strong>{$results//opensearch:totalResults/text()}{$config:nbsp}<i18n:text key="workingPapers">Working Papers</i18n:text>.</strong>{$config:nbsp}
                              <i18n:text key="display">Anzeige</i18n:text>:{$config:nbsp}{xs:integer($offset) + 1}-{xs:integer($offset) + count($results//item)}
                            </p>
        let $prevPageLink := if (xs:integer($results//opensearch:startIndex/text()) > 1 ) then
                                <span><a href="search.html?field={$field}&amp;q={$q}&amp;offset={$offset - $limit}&amp;limit={$limit}"  class="prevnext_majorList"><i18n:text key="prev">Vorige</i18n:text> <i18n:text key="prev">Werke</i18n:text></a>{$config:nbsp || $config:nbsp}</span>
                             else ()
        let $nextPageLink := if (xs:integer($results//opensearch:startIndex/text())+xs:integer($results//opensearch:itemsPerPage/text())-1 lt xs:integer($results//opensearch:totalResults/text())) then
                                <a href="search.html?field={$field}&amp;q={$q}&amp;offset={$offset + $limit}&amp;limit={$limit}" class="prevnext_majorList"><i18n:text key="next">Nächste</i18n:text> <i18n:text key="prev">Werke</i18n:text></a>
                             else ()
        let $workingPapersList :=   <ul class="resultsList">{
                                    for $item at $index in $results//item
                                        let $author         := $item/author/text()
                                        let $title          := $item/title/text()
                                        let $wid            := $item/work/text()
                                        let $numberOfHits   := $item/sphinxNS:groupcount/text()
                                        let $link           :=  if (contains($item/fragment_path/text(), "#")) then
                                                                    replace($item/fragment_path/text(), '#', '&amp;q=' || encode-for-uri($q) || '#')
                                                                else if (contains($item/fragment_path/text(), "?")) then
                                                                    $item/fragment_path/text() || '&amp;q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                                                else
                                                                    $item/fragment_path/text() || '?q=' || encode-for-uri($q)    (: this is the url to call the frg. in the webapp :)
                                        let $detailsLink    := <a class="toggleDetails" href="#details_{$wid}" data-target="#details_{$wid}" data-toggle="collapse">{$numberOfHits}&#xA0;<i18n:text key="hits">Fundstellen</i18n:text>&#xA0;<i class="fa fa-chevron-down"aria-hidden="true"></i></a>
                                        let $detailHTML     := sphinx:details($wid, $field, $q, 0, 10, $lang)
                                        return
                                            <li>
                                                <a href="{$link}">{$author}: {$title}</a><br/>
                                                {$detailsLink}
                                                <div id="details_{$wid}" class="collapse resultsDetails">{$detailHTML}</div>
                                            </li>
                                }</ul>
        return
            <div class="searchResults">
                {$searchInfo}
                <div>
                    {$prevPageLink, $nextPageLink}
                </div>
                <div class="resultsSection">
                    {$workingPapersList}
                </div>
            </div>

    else()

    return i18n:process($output, $lang, "/db/apps/salamanca/data/i18n", session:encode-url(request:get-uri()))
};


declare function sphinx:keywords ($q as xs:string?) as xs:string {
    let $keywordsRequestHeaders := <headers></headers>
    let $keywordsRequest        := concat($config:sphinxRESTURL, "/keywords", "?q=", encode-for-uri($q))
    let $keywords               := httpclient:get($keywordsRequest, false(), $keywordsRequestHeaders)//httpclient:body/rss/channel//item/*:tokenized/text()
    return string-join($keywords, ' ')
};

declare function sphinx:excerpts ($documents as node()*, $words as xs:string) as node()* {
    let $endpoint   := concat($config:sphinxRESTURL, "/excerpts")
let $debug :=  if ($config:debug = "info") then console:log("Excerpts needed for doc[0]: " || substring(normalize-space($documents/description_orig), 0, 150)) else ()
    let $requestDoc := concat(         encode-for-uri('opts[limit]=' || $config:snippetLength),
                              '&amp;', encode-for-uri('opts[html_strip_mode]=strip'),
                              '&amp;', encode-for-uri('opts[query_mode]=true'),
                              '&amp;', encode-for-uri('words=' || $words),
                              '&amp;', encode-for-uri(concat('docs[0]=', normalize-space(replace(serialize($documents/description_orig), "%26", "%26amp%3B")))),
(:                                           normalize-space($documents/description_orig))),:)
                              '&amp;', encode-for-uri(concat('docs[1]=', normalize-space(replace(serialize($documents/description_edit), "%26", "%26amp%3B"))))
(:                                           normalize-space($documents/description_edit):)
                               )
    let $tempString := replace(replace($requestDoc, '%20', '+'), '%3D', '=')
let $debug :=  if ($config:debug = "trace") then console:log("Excerpts request body: " || $tempString) else ()
(: Querying with EXPath http client proved not to work in eXist 3.4
    let $request    := <http:request method="post">
                         <http:header name="Content-Type" value="application/x-www-form-urlencoded"/>
                         <http:body                  media-type="application/x-www-form-urlencoded" method="text">{$tempString}</http:body>
                       </http:request>
    let $response   := http:send-request($request, $endpoint)
:)
    let $response   := httpclient:post($endpoint, $tempString, true(), <headers><header name="Content-Type" value="application/x-www-form-urlencoded"/></headers>)
let $debug :=  if ($config:debug = "trace") then console:log("Excerpts response: " || serialize($response)) else ()
    let $rspBody    := if ($response//httpclient:body/@encoding = "Base64Encoded") then parse-xml(util:base64-decode($response//httpclient:body)) else $response//httpclient:body
let $debug :=  if ($config:debug = "trace") then console:log("$rspBody: " || serialize($rspBody)) else ()
let $debug :=  if ($config:debug = "trace" and $response//httpclient:body/@encoding = "Base64Encoded") then console:log("body decodes to: " || util:base64-decode($response//httpclient:body)) else ()

    return $rspBody//rss
};

declare function sphinx:highlight ($document as node(), $words as xs:string*) as node()* {
    let $endpoint   := concat($config:sphinxRESTURL, "/excerpts")

(:                                '&amp;opts[html_strip_mode]=none',:)
(:                                '&amp;opts[html_strip_mode]=retain',:)
(:                                '&amp;opts[html_strip_mode]=index',:)
(:                                '&amp;opts[html_strip_mode]=strip',:)

    let $requestDoc := concat(           encode-for-uri('opts[limit]=0'),
                                '&amp;', encode-for-uri('opts[html_strip_mode]=retain'),
                                '&amp;', encode-for-uri('opts[query_mode]=true'),
                                '&amp;', encode-for-uri(concat('words=', $words)),
                                '&amp;', encode-for-uri(concat('docs[1]=', serialize($document)))
                               )
    let $tempString := replace(replace($requestDoc, '%20', '+'), '%3D', '=')
(: Querying with EXPath http client proved not to work in eXist 3.4
    let $request    := <http:request method="post">
                         <http:body media-type="application/x-www-form-urlencoded">{$requestDoc}</http:body>
                       </http:request>
    let $response   := http:send-request($request, $endpoint)
:)
    let $response   := httpclient:post($endpoint, $tempString, true(), <headers><header name="Content-Type" value="application/x-www-form-urlencoded"/></headers>)
    let $rspBody    := if ($response//httpclient:body/@encoding = "Base64Encoded") then parse-xml(util:base64-decode($response//httpclient:body))
                       else $response//httpclient:body

    return $rspBody//rss
};

(: nicht als Parameter verfügbar:
let $sort   := request:get-parameter('sort',    '2')
let $sortby := request:get-parameter('sortby',  'sphinx_fragment_number')
let $ranker := request:get-parameter('ranker',  '2')
:)
declare
     %templates:default ("field", "everything")
     %templates:default ("limit", 10)
     %templates:default ("offset", 0)
     %templates:default ("lang", "en")
function sphinx:details ($wid as xs:string, $field as xs:string, $q as xs:string, $offset as xs:integer, $limit as xs:integer, $lang as xs:string?) {
    let $detailsRequestHeaders  := <headers></headers>
    let $conditionParameters    := "@sphinx_work ^" || $wid
    let $alsoSearchAuthorField  := if ($field eq "corpus") then "sphinx_author," else ()
    let $addConditionParameters :=  if ($field = ("headings", "entries")) then
                                        $conditionParameters || " @sphinx_hit_type =head | =titlePage"
                                    else if ($field eq "notes") then
                                        $conditionParameters || " @sphinx_hit_type =note"
                                    else if ($field eq "nonotes") then
                                        $conditionParameters || " @sphinx_hit_type !note"
                                    else
                                        $conditionParameters
    let $groupingParameters     := ""
    let $sortingParameters      := "&amp;sort=2&amp;sortby=sphinx_fragment_number&amp;ranker=2"      (: sort=2 - SPH_SORT_ATTR_ASC rank=2 - SPH_RANK_NONE :)
    let $pagingParameters       := "&amp;limit=" || $limit || "&amp;offset=" || $offset

    let $detailsRequest         := concat($config:sphinxRESTURL, "/search?q=",
                                        encode-for-uri("@(" || $alsoSearchAuthorField ||
                                                        "sphinx_description_edit,sphinx_description_orig) " || $q || $addConditionParameters),
                                        $sortingParameters,
                                        $pagingParameters)
    let $details                := httpclient:get($detailsRequest, false(), $detailsRequestHeaders)//httpclient:body/rss

    let $searchInfo :=  <p id="details_searchInfo">
                            <span id="details_searchTerms"><i18n:text key="searchFor">Suche nach</i18n:text>: {string-join($details//word[not(lower-case(./text()) eq lower-case($wid))], ', ')}<br/></span>
                            <span id="details_totalHits"><i18n:text key="found">Gefunden</i18n:text>:{$config:nbsp}<strong>{$details//opensearch:totalResults/text()}{$config:nbsp}<i18n:text key="hits">Fundstellen</i18n:text>.</strong><br/></span>
                            <span id="details_displayRange"><h3><i18n:text key="display">Anzeige</i18n:text>:{$config:nbsp}{xs:integer($offset) + 1 || '-' || xs:integer($offset) + count($details//item)}</h3></span>
                        </p>
    let $prevDetailsPara        := "&amp;limit=" || $limit || "&amp;offset=" || xs:string(xs:integer($offset) - xs:integer($details//opensearch:itemsPerPage))
    let $nextDetailsPara        := "&amp;limit=" || $limit || "&amp;offset=" || xs:string(xs:integer($offset) + xs:integer($details//opensearch:itemsPerPage))
    let $prevDetailsURL         := concat('sphinx-client.xql?mode=details&amp;q=',encode-for-uri($q), '&amp;wid=' || $wid || '&amp;sort=2&amp;sortby=sphinx_fragment_number&amp;ranker=2' , $prevDetailsPara)
    let $nextDetailsURL         := concat('sphinx-client.xql?mode=details&amp;q=',encode-for-uri($q), '&amp;wid=' || $wid || '&amp;sort=2&amp;sortby=sphinx_fragment_number&amp;ranker=2' , $nextDetailsPara)
    let $prevDetailsLink := if (xs:integer($offset) > 1 ) then
                           <a href="{$prevDetailsURL}" class="loadPrev"><i class="fa fa-chevron-left"></i>&#xA0;&#xA0;<i18n:text key="prev">Zurück</i18n:text>{$config:nbsp}|{$config:nbsp}</a>
                         else ()
    let $nextDetailsLink := if (xs:integer($offset) + xs:integer($details//opensearch:itemsPerPage) lt xs:integer($details//opensearch:totalResults)) then
                            <a href="{$nextDetailsURL}" class="loadNext">{$config:nbsp}|{$config:nbsp}<i18n:text key="next">Weiter</i18n:text>&#xA0;&#xA0;<i class="fa fa-chevron-right"></i></a>
                         else ()

    let $output :=
        <div id="detailsDiv"> <!-- id="details_{$wid}" class="collapse resultsDetails" -->
            <h3 class="text-center" id="details_displayRange">
<!--<i18n:text key="display">Anzeige</i18n:text>:{$config:nbsp}-->
               {$prevDetailsLink}{$config:nbsp}{xs:integer($offset) + 1 || '-' || xs:integer($offset) + count($details//item)}{$config:nbsp}{$nextDetailsLink}</h3>
               <div style="display:none;" class="spin100 text-center"> <i class="fa fa-spinner fa-spin"/></div>
            
            <table class="table table-hover borderless">
                {
                for $item at $detailindex in $details//item
                    let $hit_id         := $item/hit_id/text()
(:                    let $crumbtrail     := sphinx:addLangToCrumbtrail(<sal:crumbtrail>{sphinx:addQToCrumbtrail(doc($config:data-root || '/' || $wid || '_nodeIndex.xml')//sal:node[@n eq $hit_id]/sal:crumbtrail, $q)}</sal:crumbtrail>, $lang):)
                    let $crumbtrail     := <sal:crumbtrail>{sphinx:addQToCrumbtrail(doc($config:data-root || '/' || $wid || '_nodeIndex.xml')//sal:node[@n eq $hit_id]/sal:crumbtrail, $q)}</sal:crumbtrail>
(:                    let $bombtrail      := sphinx:addLangToCrumbtrail(                 sphinx:addQToCrumbtrail(doc($config:data-root || '/' || $wid || '_nodeIndex.xml')//sal:node[@n eq $hit_id]/sal:crumbtrail/a[last()], $q), $lang):)
                    let $bombtrail      :=                  sphinx:addQToCrumbtrail(doc($config:data-root || '/' || $wid || '_nodeIndex.xml')//sal:node[@n eq $hit_id]/sal:crumbtrail/a[last()], $q)

                    let $snippets       :=  <documents>
                                                <description_orig>
                                                    {$item/description_orig}
                                                </description_orig>
                                                <description_edit>
                                                    {$item/description_edit}
                                                </description_edit>
                                            </documents>
                    let $excerpts       := sphinx:excerpts($snippets, $q)
                    let $description_orig    := $excerpts//item[1]/description
                    let $description_edit    := $excerpts//item[2]/description
                    let $statusInfo     := i18n:process(if      ($item/hit_type/text() = ('head'))      then <i18n:text key="heading">Überschrift</i18n:text>
                                                        else if ($item/hit_type/text() = ('note'))      then <i18n:text key="note">Marginalnote</i18n:text>
                                                        else if ($item/hit_type/text() = ('titlePage')) then <i18n:text key="titlepage">Titelblatt</i18n:text>
                                                        else                                                 <i18n:text key="mainText">Haupttext</i18n:text>, $lang, '/db/apps/salamanca/data/i18n', 'en')
                    return
                        <tr>
                           <!--<td>
                                <a href="{$crumbtrail[last()]/@href}" title="{$statusInfo}">{xs:integer($offset) + xs:integer($detailindex) || '.' || $config:nbsp || $config:triangle}</a>
                            </td>-->
                            <td>
                                <span class="lead" style="padding-bottom: 7px; font-family: 'Junicode', 'Cardo', 'Andron', 'Cabin', sans-serif;" title="{i18n:process($statusInfo, $lang, '/db/apps/salamanca/data/i18n', 'en')}"><!--<span style="color: #777777">{$detailindex|| '. '}</span>-->{$bombtrail}</span>
                                <div class="crumbtrail">{$crumbtrail}</div>
                                <div class="result__snippet" title="{$statusInfo}">{ if ($description_edit//span) then $description_edit
                                  else if ($description_orig//span) then $description_orig
                                  else if (string-length($item/description_edit) gt $config:snippetLength) then
                                    substring($item/description_edit, 0, $config:snippetLength) || '...'
                                  else
                                    $item/description_edit/*
                                }</div>
                            </td>
                        </tr>
            }</table>
            <div class="text-center">
                {$prevDetailsLink, xs:integer($offset) + 1 || '-' || xs:integer($offset) + count($details//item), $nextDetailsLink}<br/>
               <div style="display:none;" class="spin100"> <i class="fa fa-spinner fa-spin"/></div>
            </div>
        </div>

    return i18n:process($output, $lang, "/db/apps/salamanca/data/i18n", session:encode-url(request:get-uri()))
};




declare function sphinx:help ($node as node(), $model as map(*), $lang as xs:string?) {
    let $helpfile   := doc($config:data-root || "/i18n/search_help.xml")
    let $helptext   :=   if ($lang = "de") then
                                    "div_Suchhilfe_de"
                                else if ($lang = "en") then
                                    "div_searchHelp_en"
                                else if ($lang = "es") then
                                    "div_searchHelp_es"
                                else
                                "div_searchHelp_en"
    let $html       := render:dispatch($helpfile//tei:div[@xml:id = $helptext], "html")
    return if (count($html)) then
        <div id="help" class="help">
            {sphinx:print-sectionsHelp($helpfile//tei:div[@xml:id = $helptext]/tei:div, true())}
            {$html}
        </div>
    else ()
};

declare %public function sphinx:helpToc($node as node(), $model as map(*)) {
    <div/>
};

declare %private function sphinx:print-sectionsHelp($sections as element()*, $hide as xs:boolean?) {
    let $collapseClass := if ($hide) then "collapse" else ()
    return 
        if ($sections) then
            <div id="collapseTOC" class="{$collapseClass}"> <!-- class="collapse"  -->
                <div>   <!-- class="panel panel-default" -->
                    <ul class="toc tocStyle">
                    {
                        for $section in $sections
                            let $id := '#' || $section/@xml:id
                            return
                                <li class="tocStyle">
                                    <a href="{$id}">{ $section/tei:head/text() }</a>
                                    { sphinx:print-sectionsHelp($section/tei:div, false()) }
                                </li>
                    }
                    </ul>
                </div>
            </div>
        else
            ()
};

declare function sphinx:loadSnippets($wid as xs:string*) {
    let $todo             := collection($config:tei-root)//tei:TEI[tei:text/@type = ("work_multivolume", "work_monograph", "author_article", "lemma_article", "working_paper")]/@xml:id

(:    let $dbg := console:log('Todo: ' || string-join($todo, ', ')):)
    let $hits := for $work_id in $todo
                    for $hit in collection($config:snippets-root || '/' || $work_id)
                        return $hit

    return
                <sphinx:docset>
                    {$sphinx:schema}
                    {$hits}
                </sphinx:docset>
};



(: ####====---- New Approach: Render in xQuery instead of XSLT ----====#### :)

declare function sphinx:addQToCrumbtrail($node as node()*, $q as xs:string*) as item()* {
    typeswitch($node)
        case element(a) return
            <a href="{
                        if (contains(string($node/@href), "#") and contains(string($node/@href), "?")) then
                            replace(string($node/@href), '#', '&amp;q=' || encode-for-uri($q) || '#')
                        else if (contains(string($node/@href), "?")) then
                            string($node/@href) || '&amp;q=' || encode-for-uri($q)
                        else
                            string($node/@href) || '?q=' || encode-for-uri($q)
                      }">{$node/text()}</a>
        case text() return $node
        default return local:passthruCrumbtrailQ($node, $q)
};

(: test-wise disabled since we are handling lang now with path components and it seems the following functions
   have not been called from anywhere anyway.
declare function sphinx:addLangToCrumbtrail($node as node()*, $lang as xs:string*) as item()* {
    typeswitch($node)
        case element(a) return
                <a href="{
                            if (contains(string($node/@href), "#")) then
                                replace(string($node/@href), '#', '&amp;lang=' || encode-for-uri($lang) || '#')
                            else
                                string($node/@href) || '&amp;lang=' || encode-for-uri($lang)
                        }">{$node/text()}</a>
        case text() return $node
        default return local:passthruCrumbtrailLang($node, $lang)
};

declare function local:passthruCrumbtrailLang($nodes as node()*, $lang as xs:string*) as item()* {
    for $node in $nodes/node() return sphinx:addLangToCrumbtrail($node, $lang)
};
:)

declare function local:passthruCrumbtrailQ($nodes as node()*, $q as xs:string*) as item()* {
    for $node in $nodes/node() return sphinx:addQToCrumbtrail($node, $q)
};

declare function sphinx:dispatch($node as node(), $mode as xs:string) as item()* {
    typeswitch($node)
    (: Try to sort the following nodes based (approx.) on frequency of occurences, so fewer checks are needed. :)
        case text() return $node

        case element(tei:lb)        return local:break($node, $mode)
        case element(tei:pb)        return local:break($node, $mode)
        case element(tei:cb)        return local:break($node, $mode)
        case element(tei:fw)        return ()

        case element(tei:p)         return local:p($node, $mode)
        case element(tei:note)      return local:note($node, $mode)
        case element(tei:div)       return local:div($node, $mode)
        case element(tei:milestone) return local:milestone($node, $mode)
        
        case element(tei:abbr)      return local:abbr($node, $mode)
        case element(tei:orig)      return local:orig($node, $mode)
        case element(tei:sic)       return local:sic($node, $mode)
        case element(tei:expan)     return local:expan($node, $mode)
        case element(tei:reg)       return local:reg($node, $mode)
        case element(tei:corr)      return local:corr($node, $mode)
        case element(tei:g)         return local:g($node, $mode)

        case element(tei:persName)  return local:persName($node, $mode)
        case element(tei:placeName) return local:placeName($node, $mode)
        case element(tei:term)      return local:term($node, $mode)
        case element(tei:title)     return local:title($node, $mode)
        case element(tei:bibl)      return local:bibl($node, $mode)

        case element(tei:figDesc)     return ()
        case element(tei:teiHeader)   return ()
        case comment()                return ()
        case processing-instruction() return ()

        default return local:passthru($node, $mode)
};

declare function local:passthru($nodes as node()*, $mode as xs:string) as item()* {
(:    for $node in $nodes/node() return element {name($node)} {($node/@*, sphinx:dispatch($node, $mode))}:)
    for $node in $nodes/node() return sphinx:dispatch($node, $mode)
};

declare function local:break($node as element(), $mode as xs:string) {
    if (not($node/@break = 'no')) then
        ' '
    else ()
};

declare function local:p($node as element(tei:p), $mode as xs:string) as xs:string* {
    for $subnode in $node/node() where (local-name($subnode) ne 'note') return sphinx:dispatch($subnode, $mode)
};
declare function local:note($node as element(tei:note), $mode as xs:string) as xs:string* {
    local:passthru($node, $mode)
};
declare function local:div($node as element(tei:div), $mode as xs:string) as xs:string* {
    if ($mode = "edit") then
        if ($node/@n and not(matches($node/@n, '^[0-9]+$'))) then
            concat(' ', string($node/@n), ' ', local:passthru($node, $mode))
(: oder das hier?:   <xsl:value-of select="key('targeting-refs', concat('#',@xml:id))[1]"/> :)
        else local:passthru($node, $mode)
    else local:passthru($node, $mode)
};
declare function local:milestone($node as element(tei:milestone), $mode as xs:string) as xs:string* {
    ()
(:    if ($mode = "edit") then
        if ($node/@n and not(matches($node/@n, '^[0-9]+$'))) then
            concat(' ', string($node/@n), ' ')
(\: oder das hier?:   <xsl:value-of select="key('targeting-refs', concat('#',@xml:id))[1]"/> :\)
        else ()
    else ()
:)
};

declare function local:abbr($node as element(tei:abbr), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if (not($node/preceding-sibling::tei:expan|$node/following-sibling::tei:expan)) then
            local:passthru($node, $mode)
        else ()
};
declare function local:orig($node as element(tei:orig), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if (not($node/preceding-sibling::tei:reg|$node/following-sibling::tei:reg)) then
            local:passthru($node, $mode)
        else ()
};
declare function local:sic($node as element(tei:sic), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if (not($node/preceding-sibling::tei:corr|$node/following-sibling::tei:corr)) then
            local:passthru($node, $mode)
        else ()
};
declare function local:expan($node as element(tei:expan), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then ()
    else
        local:passthru($node, $mode)
};
declare function local:reg($node as element(tei:reg), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then ()
    else
        local:passthru($node, $mode)
};
declare function local:corr($node as element(tei:corr), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then ()
    else
        local:passthru($node, $mode)
};
declare function local:g($node as element(tei:g), $mode as xs:string) as xs:string* {
    if ($mode="orig") then
        let $glyph := $node/ancestor::tei:TEI//tei:char[@xml:id eq substring($node/@ref,2)] (: remove leading '#' :)
        return if ($glyph/tei:mapping[@type = 'precomposed']) then
                $glyph/tei:mapping[@type = 'precomposed']/string()
            else if ($glyph/tei:mapping[@type = 'composed']) then
                $glyph/tei:mapping[@type = 'composed']/string()
            else if ($glyph/tei:mapping[@type = 'standardized']) then
                $glyph/tei:mapping[@type = 'standardized']/string()
            else
                local:passthru($node, $mode)
    else
        local:passthru($node, $mode)
};

declare function local:persName($node as element(tei:persName), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if ($node/@key and $node/@ref) then
            string($node/@key) || ' [' || string($node/@ref) || ']'
        else if ($node/@key) then
            string($node/@key)
        else if ($node/@ref) then
            '[' || string($node/@ref) || ']'
        else
            local:passthru($node, $mode)
};
declare function local:placeName($node as element(tei:placeName), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if ($node/@key) then
            string($node/@key)
        else
            local:passthru($node, $mode)
};
declare function local:term($node as element(tei:term), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if ($node/@key) then
            string($node/@key)
        else
            local:passthru($node, $mode)
};
declare function local:title($node as element(tei:title), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if ($node/@key) then
            string($node/@key)
        else
            local:passthru($node, $mode)
};
declare function local:bibl($node as element(tei:bibl), $mode as xs:string) as xs:string* {
    if ($mode = "orig") then
        local:passthru($node, $mode)
    else
        if ($node/@sortKey) then
            replace(string($node/@sortKey), '_', ', ')
        else
            local:passthru($node, $mode)
};

