# One-time read-only export: includes hidden covers without changing the design.
import adsk.core, adsk.fusion, json

def run(_context: str):
    doc = adsk.core.Application.get().activeDocument
    if doc.name != 'CNC simplified v31':
        raise RuntimeError('Expected the supplied CNC simplified v31 source document.')
    before = doc.isModified
    design = adsk.fusion.Design.cast(doc.products.itemByProductType('DesignProductType'))
    path = '/Users/pd/Project/coastline/coastline/resources/machine-profile-sources/desktop-cnc-full.step'
    options = design.exportManager.createSTEPExportOptions(path, design.rootComponent)
    options.isIncludingInvisibleBodies = True
    options.isIncludingInvisibleComponents = True
    success = design.exportManager.execute(options)
    if not success:
        raise RuntimeError('Full STEP export failed.')
    print(json.dumps({'path':path,'document':doc.name,'modifiedBefore':before,'modifiedAfter':doc.isModified,'includeInvisibleBodies':options.isIncludingInvisibleBodies,'includeInvisibleComponents':options.isIncludingInvisibleComponents,'bodyCount':sum(o.bRepBodies.count for o in design.rootComponent.allOccurrences)}))
