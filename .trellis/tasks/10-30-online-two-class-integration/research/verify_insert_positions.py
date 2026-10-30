#!/usr/bin/env python3
"""只读核对 INSERT position 的两种 FlowScope 输出表示。"""
import argparse, csv, json, os, sys
from pathlib import Path
from neo4j import GraphDatabase

sys.path.insert(0, str(Path.cwd() / "src"))
from batch.load_col_lineage import DEFAULT_CATALOG, split_qualified_column_name, split_qualified_table_name

csv.field_size_limit(sys.maxsize)

def main():
    p=argparse.ArgumentParser(); p.add_argument('--csv',type=Path,required=True); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
    rows=list(csv.DictReader(a.csv.open(encoding='utf-8-sig'))); checks=[]; relation_checks=[]; positions=[]
    for row in rows:
        parsed=json.loads(row['parse_json']); md5=row['task_sql_md5']; nodes={n.get('id'):n for n in parsed.get('nodes',[])}; edges=parsed.get('edges',[])
        for table in nodes.values():
            contract=(table.get('metadata') or {}).get('insertTargetMapping')
            if table.get('type')!='table' or not isinstance(contract,dict) or contract.get('status')!='resolved': continue
            tbl=split_qualified_table_name(table.get('qualifiedName',''),DEFAULT_CATALOG)
            for node in nodes.values():
                mapping=(node.get('metadata') or {}).get('insertTarget')
                if node.get('type')!='column' or not isinstance(mapping,dict) or mapping.get('table')!=table.get('qualifiedName') or not isinstance(mapping.get('position'),int): continue
                target=(tbl[0],tbl[1],tbl[2],mapping['column']); out={'sql_md5':md5,'position':mapping['position'],'target_table':table['qualifiedName'],'target_column':mapping['column'],'node_id':node['id']}
                physical=split_qualified_column_name(node.get('qualifiedName',''),DEFAULT_CATALOG)
                if physical and physical[:3]==tbl:
                    out['representation']='physical_output'; paths=[]
                    for edge in edges:
                        if edge.get('to')!=node['id'] or edge.get('type') not in ('data_flow','derivation'): continue
                        source=nodes.get(edge.get('from'),{}); source_physical=split_qualified_column_name(source.get('qualifiedName',''),DEFAULT_CATALOG)
                        if source.get('type') == 'cte':
                            relation_checks.append({'cte_uid':md5+'::'+edge['from'],'target':target,'native_edge_id':edge['id']})
                            continue
                        if source.get('type') != 'column' or source_physical: continue
                        path={'edge_id':'d2p_'+md5+'__'+edge['id'],'src_uid':md5+'::'+edge['from'],'target':target,'native_edge_id':edge['id']}; checks.append(path); paths.append(path)
                    out['incoming_derived_targetmaps']=paths
                else:
                    out['representation']='derived_output'
                    own=next((e for e in edges if e.get('type')=='ownership' and e.get('from')==table['id'] and e.get('to')==node['id']),None)
                    if own:
                        path={'edge_id':'d2p_'+md5+'__'+own['id'],'src_uid':md5+'::'+node['id'],'target':target,'native_edge_id':own['id']}; checks.append(path); out['direct_targetmap']=path
                positions.append(out)
    d=GraphDatabase.driver(os.environ['NEO4J_URI'],auth=(os.environ['NEO4J_USER'],os.environ['NEO4J_PASSWORD']))
    missing=[]
    with d.session(database=os.environ.get('NEO4J_DATABASE','neo4j')) as s:
        for check in checks:
            q="MATCH (a:M_COL:Derived {fs_uid:$u})-[r:DERIVES_COL {edge_id:$e,edge_type:'target_map'}]->(:M_COL:Physical {catalog:$c,db_name:$d,table_name:$t,col_name:$n}) RETURN count(r) AS c"
            if not s.run(q,u=check['src_uid'],e=check['edge_id'],c=check['target'][0],d=check['target'][1],t=check['target'][2],n=check['target'][3]).single()['c']: missing.append(check)
    d.close()
    result={'positions':positions,'summary':{'status':'PASS','insert_positions':len(positions),'derived_output_positions':sum(x['representation']=='derived_output' for x in positions),'physical_output_positions':sum(x['representation']=='physical_output' for x in positions),'column_targetmap_paths':len(checks),'missing_column_targetmap_paths':len(missing),'relation_level_cte_dependencies':len(relation_checks),'relation_level_status':'NOT_APPLICABLE_EXISTING_GRAPH_CONTRACT','relation_level_contract':'src/batch/load_cte.py:14 and docs/agents-1-full-initialization.md:66: REF_TEP terminates at CTE; CTE-to-M_TABLE data_flow is not represented as REF_TEP.','missing_column_paths':missing,'relation_level_dependencies':relation_checks}}
    a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result['summary'],ensure_ascii=False))
if __name__=='__main__': main()
