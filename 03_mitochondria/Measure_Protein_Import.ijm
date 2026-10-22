// Protein import workflow: how much of a reporter or protein gets into a compartment, measured per cell.
//   Organelle import: a targeted reporter (e.g. MTS-GFP, GFP-SKL, ss-GFP-KDEL) into mitochondria, peroxisomes,
//   the ER or another organelle with its own marker.
//   Nuclear import: a reporter or a stained protein (e.g. NLS-GFP, IRF3, NF-kB p65, STAT1) into the nucleus.
//
//   1. Choose the compartment, whether the reporter is transfected (untransfected cells are skipped) or an
//      endogenous stained protein (every cell is measured), and "Control vs treated" (control folder, then one or
//      more treated folders, e.g. doses) or "Absolute" (one file or one folder). A folder can hold the images
//      directly or one subfolder per replicate. Any Bio-Formats format.
//   2. Channels. Organelle: the reporter, the organelle marker (TOM20, PMP70, Sec61b ...), a cell-fill marker
//      (mCherry ...) and nuclei (DAPI, Hoechst); without a cell-fill marker the reporter outlines the cells,
//      without nuclei touching cells are not split. Nucleus: the reporter, nuclei and an optional cell-fill marker;
//      without one, the cytoplasm is a ring (3 um) around each nucleus.
//   3. Cells: each nucleus seeds one cell; the cell-fill marker (smoothed max projection, Triangle threshold by
//      default) gives its extent; touching cells are split on the line halfway between their nuclei. A cell needs
//      its own nucleus inside the outline. With a transfected reporter, cells below 30% of the median cell (all
//      images) are untransfected: listed and marked on the QC image, not measured. Cells cut by the image edge
//      are measured and flagged (the readouts are ratios within the visible part); they can be excluded instead.
//   4. The cells in 3D: the cell-fill marker (or the reporter), smoothed, with the same threshold in every slice;
//      cytosol and nucleus voxels count only inside it (empty voxels above a thin cytoplasm would dilute it).
//   5. Compartment. Organelle: the marker is prepared slice by slice (rolling ball, 1-pixel Gaussian, remaining
//      background set to 0) and outlined with ONE threshold for all images (Otsu on the control images by
//      default, adjustable in a live window), widened by a margin for the blur of the reporter's light.
//      Nucleus: the DAPI outline through the slices; a 0.5 um band around it is left out of the cytoplasm.
//   6. The reporter is measured in every slice, never on a projection (a projection stacks the cytosol above and
//      below onto the compartment). Only its background is subtracted (median outside the cells): its diffuse
//      cytosolic signal is what an import defect looks like, so no rolling ball.
//   7. Readouts per cell:
//        imported fraction             share of the cell's reporter inside the organelle above the cytosolic
//                                      level (blur puts cytosolic light into the outline; the cytosolic level x
//                                      the outline's volume is subtracted). Headline.
//        nuclear fraction              share of the cell's reporter in the nucleus (no subtraction: proteins
//                                      diffuse into the nucleus, so the cytoplasmic level there is real)
//        compartment / cytosol         mean reporter in the compartment / mean in the cytosol (N/C ratio for
//                                      the nucleus)
//        nucleus / organelle           unimported organelle reporter enters nuclei (organelle import only)
//        Pearson                       reporter vs organelle marker over the cell's voxels (organelle only)
//        reporter and cell-marker levels, compartment volume
//   8. Writes protein_import_results.xlsx (Summary relative to control, Replicates, Images, Cells, Threshold methods,
//      Settings), bar graphs, and qc/ images (reporter green, compartment marker magenta, measured cells yellow with
//      their number, excluded cells marked, nuclei cyan). Deconvolved stacks give more accurate fractions.
//      Statistics use replicate means when every condition has >= 2 replicate subfolders, otherwise image means
//      (mean of the image's measured cells); never pooled cells.

// ---- settings ----
interactive = true;          // false = use the defaults below without dialogs (testing)
// ------------------

requires("1.54");
setOption("BlackBackground", true);
run("Options...", "iterations=1 count=1 black");

// ---- 1. what to measure ----
targets = newArray("Mitochondria", "Peroxisomes", "Endoplasmic reticulum", "Other organelle (with its own marker)", "Nucleus");
reporters = newArray("Transfected reporter (untransfected cells are skipped)", "Endogenous protein, stained (every cell is measured)");
modes = newArray("Control vs treated (one or more treated folders, e.g. doses)", "Absolute (no comparison)");
inputs = newArray("A folder", "One file");
target = targets[0]; reporterType = reporters[0]; mode = modes[0]; input = inputs[0];
if (interactive) {
    Dialog.create("Protein import");
    Dialog.addChoice("Import into", targets, target);
    Dialog.addRadioButtonGroup("Reporter", reporters, 2, 1, reporterType);
    Dialog.addRadioButtonGroup("Analysis", modes, 2, 1, mode);
    Dialog.addMessage("Organelle import: the reporter, the organelle's marker, a cell-fill marker and nuclei.\n"
        + "Nucleus: the reporter (e.g. NLS-GFP, IRF3, p65, STAT1), nuclei and an optional cell-fill marker.\n"
        + "Control vs treated: you will pick the control folder, then a treated folder; you can then add\n"
        + "more treated folders (other doses or drugs). Absolute: measure one file or one folder on its own.\n"
        + "A folder can hold the images directly or one subfolder per replicate. Use raw or deconvolved stacks.");
    Dialog.show();
    target = Dialog.getChoice(); reporterType = Dialog.getRadioButton(); mode = Dialog.getRadioButton();
    if (mode == modes[1]) {
        Dialog.create("Protein import: absolute");
        Dialog.addRadioButtonGroup("Measure", inputs, 1, 2, input);
        Dialog.show();
        input = Dialog.getRadioButton();
    }
}
nuclear = false; if (target == "Nucleus") nuclear = true;
transfected = true; if (reporterType == reporters[1]) transfected = false;
// per compartment: short name, marker names to look for, rolling-ball radius (um), margin (um)
orgShort = "Mito"; markerRe = "tom ?20|tom ?70|mito|cox|hsp60|tfam|640|647|cy5"; bgRadius = 1; margin = 0.2;
if (target == targets[1]) { orgShort = "Peroxisome"; markerRe = "pmp70|catalase|pex|abcd3|640|647|cy5"; bgRadius = 0.5; margin = 0.15; }
if (target == targets[2]) { orgShort = "ER"; markerRe = "sec61|calnex|calret|pdi|er ?tracker|bip|grp78|640|647|cy5"; bgRadius = 2; margin = 0.2; }
if (target == targets[3]) { orgShort = "Organelle"; markerRe = "640|647|cy5"; bgRadius = 1; margin = 0.2; }
if (nuclear) { orgShort = "Nucleus"; margin = 0.5; }
orgLow = toLowerCase(orgShort); if (orgShort == "ER") orgLow = "ER";
fracName = "Imported fraction"; ratioName = orgShort + " / cytosol ratio"; nucName = "Nucleus / " + orgLow + " ratio";
if (nuclear) { fracName = "Nuclear fraction"; ratioName = "Nucleus / cytoplasm ratio (N/C)"; }
compare = false; if (mode == modes[0]) compare = true;
fPath = newArray(); fCond = newArray(); fRep = newArray();
if (compare) {
    ctrlDir = getDirectory("Select the CONTROL folder");
    dirs = newArray(ctrlDir);
    trtDir = getDirectory("Select a TREATED folder");
    dirs = Array.concat(dirs, trtDir);
    while (interactive) {
        more = getBoolean("" + (dirs.length - 1) + " treated folder(s) selected.\nAdd another treated folder (another dose or drug)?", "Add another", "No, continue");
        if (!more) break;
        d = getDirectory("Select TREATED folder " + dirs.length);
        dirs = Array.concat(dirs, d);
    }
    condNames = newArray(dirs.length);
    dup = false;
    for (g = 0; g < dirs.length; g++) {
        condNames[g] = folderName(dirs[g]);
        for (h = 0; h < g; h++) {
            same = sameFolder(dirs[g], dirs[h]);
            if (same) exit("The same folder was selected twice:\n" + dirs[g]);
            if (condNames[g] == condNames[h]) dup = true;
        }
    }
    if (dup) { condNames[0] = "Control"; for (g = 1; g < dirs.length; g++) condNames[g] = "Treated " + g; }
    for (g = 0; g < dirs.length; g++) {
        list = collect(dirs[g]);
        if (list.length == 0) exit("No microscope files in\n" + dirs[g]);
        for (i = 0; i < list.length; i++) {
            f = split(list[i], "\t");
            fRep = Array.concat(fRep, f[0]); fPath = Array.concat(fPath, f[1]); fCond = Array.concat(fCond, g);
        }
    }
} else {
    if (input == inputs[1]) {
        onePath = File.openDialog("Select the image file");
        list = newArray("-\t" + onePath);
        n0 = File.getNameWithoutExtension(onePath);
        if (endsWith(n0, ".ome")) n0 = substring(n0, 0, lengthOf(n0) - 4);
        condNames = newArray(n0);
    } else {
        absDir = getDirectory("Select the image folder");
        list = collect(absDir);
        n0 = folderName(absDir);
        condNames = newArray(n0);
    }
    if (list.length == 0) exit("No microscope files found.");
    for (i = 0; i < list.length; i++) {
        f = split(list[i], "\t");
        fRep = Array.concat(fRep, f[0]); fPath = Array.concat(fPath, f[1]); fCond = Array.concat(fCond, 0);
    }
}
outDir = getDirectory("Choose a folder for the results");
nCond = condNames.length;

// ---- 2. options (channels read from the first file) ----
lines = split(readMetadata(fPath[0]), "\n");
if (startsWith(lines[0], "E")) exit(File.getName(fPath[0]) + " could not be read; it is used to read the channel names.");
chNames = newArray();
for (i = 0; i < lines.length; i++) {
    f = split(lines[i], "\t");
    if (f[0] == "C") { if (parseInt(f[1]) == 0) chNames = Array.concat(chNames, "C" + (parseInt(f[2]) + 1) + " " + f[3]); }
}
nCh = chNames.length;
if (nCh < 2 && !nuclear) exit("Organelle import needs at least two channels: the reporter and the organelle marker.");
if (nCh < 2 && nuclear) exit("Nuclear import needs at least two channels: the reporter and nuclei (DAPI, Hoechst).");
// defaults: a channel named like the dye (or shown green / blue for the reporter / nuclei, as set in the file),
// otherwise the usual order. Organelle import: 2 channels = reporter, organelle; 3 = nuclei, reporter, organelle;
// 4 = nuclei, reporter, cell fill, organelle. Nuclear import: nuclei, reporter, then a cell fill if there is one.
kG = channelLike(chNames, "gfp|488|fitc|alexa ?488|irf3|p65|stat|nls|\\(green", minOf(1, nCh - 1));
kM = channelLike(chNames, markerRe, nCh - 1);
if (kM == kG) { kM = nCh - 1; if (kM == kG) kM = 0; }
kN = channelLike(chNames, "dapi|hoechst|405|nuc|\\(blue", 0);
fillDefault = -1; if (nCh >= 4 || (nuclear && nCh >= 3)) fillDefault = 2;
kC = channelLike(chNames, "cherry|rfp|tdtomato|dsred|fill|cellmask", fillDefault);
NONE_CELL = "None (the reporter outlines the cells)"; NONE_NUC = "None (touching cells are not split)";
if (nuclear) NONE_CELL = "None (the cytoplasm is a ring around each nucleus)";
cellChoices = Array.concat(NONE_CELL, chNames); nucChoices = Array.concat(NONE_NUC, chNames);
gfpCh = chNames[kG]; mitoCh = chNames[kM];
cellCh = NONE_CELL; if (kC >= 0 && kC < nCh && kC != kG && kC != kN && (nuclear || kC != kM)) cellCh = chNames[kC];
nucCh = NONE_NUC; if ((nCh >= 3 || nuclear) && kN != kG && (nuclear || kN != kM)) nucCh = chNames[kN];
methods = getList("threshold.methods");
cellMethod = "Triangle";
minCell = 100;         // um^2
minNuc = 20;           // um^2, smaller nuclear pieces are ignored
nucMethod = "Otsu";    // nuclei threshold (Li catches dim nuclei next to bright ones; Otsu ignores cytoplasmic DAPI haze)
minRel = 30;           // %: a cell whose reporter is below this share of the median cell is untransfected
ring = 3;              // um, cytoplasm ring around each nucleus (nucleus mode without a cell-fill marker)
excludeEdge = false;
if (interactive) {
    Dialog.create("Protein import: options");
    if (compare) {
        for (g = 0; g < nCond; g++) {
            nf = countOf(fCond, g);
            label = "Control name"; if (g > 0) label = "Treated " + g + " name";
            Dialog.addString(label, condNames[g], 20);
            Dialog.addToSameRow(); Dialog.addMessage("(" + nf + " files)");
        }
    } else Dialog.addMessage("" + fPath.length + " file(s)");
    Dialog.addChoice("Reporter", chNames, gfpCh);
    if (!nuclear) Dialog.addChoice(orgShort + " marker", chNames, mitoCh);
    if (nuclear) { Dialog.addChoice("Nuclei", chNames, nucCh); Dialog.addToSameRow(); Dialog.addChoice("threshold", newArray("Otsu", "Li", "Huang", "Triangle"), nucMethod); }
    Dialog.addChoice("Cell-fill marker", cellChoices, cellCh);
    if (!nuclear) { Dialog.addChoice("Nuclei", nucChoices, nucCh); Dialog.addToSameRow(); Dialog.addChoice("threshold", newArray("Otsu", "Li", "Huang", "Triangle"), nucMethod); }
    Dialog.addChoice("Cell outline threshold", methods, cellMethod);
    Dialog.addNumber("Minimum cell area", minCell, 0, 6, "um2");
    if (transfected) Dialog.addNumber("Minimum reporter level", minRel, 0, 6, "% of the median cell (dimmer cells = untransfected)");
    if (nuclear) Dialog.addNumber("Cytoplasm ring", ring, 1, 6, "um around each nucleus (only without a cell-fill marker)");
    if (nuclear) Dialog.addNumber("Gap around the nucleus", margin, 2, 6, "um (left out of the cytoplasm: blur of the nuclear light)");
    else Dialog.addNumber(orgShort + " margin", margin, 2, 6, "um (blur of the reporter's light)");
    if (!nuclear) Dialog.addNumber("Background radius", bgRadius, 1, 6, "um (organelle marker only)");
    Dialog.addCheckbox("Exclude cells cut by the image edge", excludeEdge);
    msg = "Triangle follows the dim edges of the cells; the qc/ images show every outline.\n"
        + "Cells cut by the edge are measured by default: the readouts are ratios within the visible part.";
    if (target == targets[2]) msg = msg + "\nER: the ER fills much of the cytoplasm, so the cytosol is thin; the ER / cytosol ratio is the\nmore reliable readout, the imported fraction less so.";
    Dialog.addMessage(msg);
    Dialog.show();
    if (compare) for (g = 0; g < nCond; g++) condNames[g] = Dialog.getString();
    gfpCh = Dialog.getChoice();
    if (!nuclear) mitoCh = Dialog.getChoice();
    if (nuclear) { nucCh = Dialog.getChoice(); nucMethod = Dialog.getChoice(); }
    cellCh = Dialog.getChoice();
    if (!nuclear) { nucCh = Dialog.getChoice(); nucMethod = Dialog.getChoice(); }
    cellMethod = Dialog.getChoice();
    minCell = Dialog.getNumber();
    if (transfected) minRel = Dialog.getNumber();
    if (nuclear) ring = Dialog.getNumber();
    margin = Dialog.getNumber();
    if (!nuclear) bgRadius = Dialog.getNumber();
    excludeEdge = Dialog.getCheckbox();
}
if (!transfected) minRel = 0;
for (c = 0; c < nCond; c++) condNames[c] = replace(condNames[c], "[,{}|'\t]", " ");
cG = chIndex(gfpCh); cM = chIndex(mitoCh); cC = chIndex(cellCh); cN = chIndex(nucCh);   // 0 = none
if (nuclear) { cM = cN; mitoCh = nucCh; }
if (nuclear && cN == 0) exit("Nuclear import needs the nuclei channel.");
if (cG == cM) exit("The reporter and the " + orgLow + " marker must be different channels.");
if (cC == cG) cC = 0;
ringMode = false; if (nuclear && cC == 0) ringMode = true;   // cytoplasm = a ring around the nucleus, not the whole cell
qcDir = outDir + "qc" + File.separator;
File.makeDirectory(qcDir);
setBatchMode(true);
skipped = "";

// ---- 3. threshold for the organelle marker: every method on the prepared stacks of the reference images ----
T = NaN; method = "-"; nRef = 0; methodRows = "";
if (!nuclear) {
    nM = methods.length; NB = 1024;
    refT = newArray(); hv = newArray(); hc = newArray(); maxV = 0; prevTitle = "";
    for (fi = 0; fi < fPath.length; fi++) {
        if (fCond[fi] != 0) continue;
        use = usableSeries(fPath[fi]);
        for (u = 0; u < use.length; u++) {
            s = use[u];
            if (s < 0) { if (s == -1) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
            one = newArray(1); one[0] = cM;
            err = loadChannels(fPath[fi], s, one, newArray("tom"));
            if (err != "") { skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
            bgT = prepare("tom", bgRadius);
            selectWindow("tom");
            for (m = 0; m < nM; m++) {
                setAutoThreshold(methods[m] + " dark stack");
                getThreshold(lo, hi);
                refT = Array.concat(refT, lo);
            }
            resetThreshold();
            Stack.getStatistics(nv, mean, mn, mx);
            hist = stackHistogram(NB, mn, mx);
            hv = Array.concat(hv, Array.slice(hist, 0, NB)); hc = Array.concat(hc, Array.slice(hist, NB, 2 * NB));
            maxV = maxOf(maxV, mx);
            nRef++;
            if (prevTitle == "") { rename("preview"); prevTitle = "preview"; } else close("tom");
        }
    }
    if (nRef == 0) exit("None of the " + condNames[0] + " images could be read.\n" + skipped);
    mT = newArray(nM); mPct = newArray(nM); otsu = 0;
    for (m = 0; m < nM; m++) {
        t = newArray(nRef);
        for (r = 0; r < nRef; r++) t[r] = refT[r * nM + m];
        mT[m] = medianOf(t);
        for (r = 0; r < nRef; r++) { st = scoreThreshold(hv, hc, r * NB, NB, mT[m]); mPct[m] = mPct[m] + st[1] / nRef; }
        if (methods[m] == "Otsu") otsu = m;
    }
    byValue = Array.rankPositions(mT);
    order = newArray(1); order[0] = otsu;
    for (k = 0; k < nM; k++) if (byValue[k] != otsu) order = Array.concat(order, byValue[k]);
    labels = newArray(nM); ordT = newArray(nM);
    for (k = 0; k < nM; k++) {
        m = order[k]; ordT[k] = mT[m];
        labels[k] = methods[m] + ":  " + d2s(mT[m], 1) + "   (" + d2s(mPct[m], 1) + "% of the voxels outlined)";
        if (k == 0) labels[k] = labels[k] + "  default";
    }
    T = ordT[0]; method = methods[order[0]];
    if (interactive) {
        selectWindow("preview");
        setSlice(maxOf(1, round(nSlices / 2)));
        run("Grays");
        run("Enhance Contrast", "saturated=0.35");
        setBatchMode("show");
        msg = "Every threshold method was tried on the " + orgLow + " marker of " + nRef + " " + condNames[0] + " image(s)\n"
            + "(prepared stacks). Default: Otsu; the other methods are listed from low to high.\n"
            + "Yellow outlines = what counts as " + orgLow + " in this slice: they should follow the organelle,\n"
            + "not the haze around it. Type a value, move the slider or pick a method; scroll through the slices.\n"
            + "This one value is applied to every slice of every image.";
        r = thresholdDialog("Protein import: " + orgLow + " threshold", msg, labels, ordT, maxV);
        if (r == "cancel") exit;
        if (startsWith(r, "ERR")) exit("Threshold window failed: " + r);
        f = split(r, "\t"); T = parseFloat(f[0]); method = methods[order[parseInt(f[1])]];
        if (f[2] == "1") method = method + " (edited)";
    }
    close("preview");
    print(orgShort + " threshold: " + T + " (" + method + ", from " + nRef + " images)");
    methodRows = "Method\tThreshold (prepared marker)\tOutlined voxels (%)\n";
    for (k = 0; k < nM; k++) { m = order[k]; methodRows = methodRows + methods[m] + "\t" + d2s(mT[m], 3) + "\t" + d2s(mPct[m], 3) + "\n"; }
}

// ---- 4. measure every cell of every image ----
iCond = newArray(); iRep = newArray(); iFile = newArray(); iSer = newArray(); iQc = newArray(); iW = newArray();
iBg = newArray(); iNoise = newArray(); iPx = newArray(); iNz = newArray();
cImg = newArray(); cLabel = newArray(); cEdge = newArray(); cArea = newArray(); cLevel = newArray(); cMarker = newArray(); cX = newArray(); cY = newArray();
cFrac = newArray(); cRatio = newArray(); cNuc = newArray(); cPear = newArray(); cVol = newArray(); cRaw = newArray();
noBgList = ""; rpx = 1;
for (fi = 0; fi < fPath.length; fi++) {
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (s == -1 && fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
        chs = newArray(cG, cM); names = newArray("gfp", "tom");
        if (cC > 0) { chs = Array.concat(chs, cC); names = Array.concat(names, "cellch"); }
        if (cN > 0) { chs = Array.concat(chs, cN); names = Array.concat(names, "nucch"); }
        err = loadChannels(fPath[fi], s, chs, names);
        if (err != "") { if (fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        name = File.getName(fPath[fi]);
        cname = condNames[fCond[fi]];
        qb = qcBase(cname, fRep[fi], name, s, use.length);
        selectWindow("gfp");
        getVoxelSize(pw, ph, pd, unit);
        W = getWidth(); H = getHeight();
        // cells (2D): cell-fill marker outline (or the reporter, or a ring around each nucleus), split between nuclei
        cellSource = "gfp"; if (cC > 0) cellSource = "cellch";
        ringUm = 0; if (nuclear && cC == 0) ringUm = ring;
        nCells = segmentCells(cellSource, cN, false, minCell, minNuc, cellMethod, nucMethod, ringUm, pw);
        selectWindow("gfp"); nz = nSlices;
        // the cells in 3D: the cell-fill marker (or the reporter) smoothed and thresholded with Otsu in every slice, so
        // the voxels above and below a thin cytoplasm are not counted as cytosol (Otsu, not the outline's Triangle:
        // the dim halo Triangle keeps would dilute the cytosol)
        selectWindow(cellSource); run("Duplicate...", "title=c301 duplicate");
        sg = maxOf(1, 1 / pw);
        if (nSlices > 1) run("Gaussian Blur 3D...", "x=" + sg + " y=" + sg + " z=1"); else run("Gaussian Blur...", "sigma=" + sg);
        setAutoThreshold("Otsu dark stack");
        run("Convert to Mask", "background=Dark black");
        run("Divide...", "value=255 stack"); run("32-bit"); rename("c301");
        // reporter background and noise: outside the cells (cell outline widened by 2 um), over the slices
        bgN = outsideStats("gfp", "cellmask", 2 / pw);
        gBg = bgN[0]; gNoise = bgN[1];
        if (bgN[2] < 0.02) noBgList = noBgList + name + "\n";
        tN = outsideStats("tom", "cellmask", 2 / pw);
        selectWindow("gfp"); run("Subtract...", "value=" + gBg + " stack");
        selectWindow("tom"); run("Duplicate...", "title=tomraw duplicate"); run("Subtract...", "value=" + tN[0] + " stack");
        rpx = maxOf(1, round(margin / pw));
        if (nuclear) {
            // the compartment is the nucleus through the slices; the gap around it is left out of the cytoplasm
            newImage("m01", "32-bit black", W, H, nz); imageCalculator("Add stack", "m01", "nuc01");
            imageCalculator("Multiply stack", "m01", "c301");        // nuclear voxels inside the cell (not above or below it)
            selectWindow("nucmask"); run("Duplicate...", "title=nucd"); run("Maximum...", "radius=" + rpx); run("32-bit"); run("Divide...", "value=255");
            newImage("md01", "32-bit black", W, H, nz); imageCalculator("Add stack", "md01", "nucd"); close("nucd");
            close("tom");
        } else {
            // organelle: prepared marker >= T in every slice; the margin added for the reporter's blur
            bgT = prepare("tom", bgRadius);
            selectWindow("tom");
            setThreshold(T, 1e30);
            run("Convert to Mask", "background=Dark black");
            run("Divide...", "value=255 stack"); run("32-bit"); rename("m01");
            selectWindow("m01"); run("Duplicate...", "title=md01 duplicate");
            run("Maximum...", "radius=" + rpx + " stack");
        }
        // cytosol and nucleus voxels: inside the cell in 3D, outside the compartment + margin
        newImage("nucCol", "32-bit black", W, H, nz); imageCalculator("Add stack", "nucCol", "nuc01");
        selectWindow("md01"); run("Duplicate...", "title=cyt01 duplicate"); run("Multiply...", "value=-1 stack"); run("Add...", "value=1 stack");
        imageCalculator("Multiply stack", "cyt01", "c301");               // in the cell, outside compartment + margin
        imageCalculator("Multiply create 32-bit stack", "cyt01", "nucCol"); rename("nv01");   // ... and in the nucleus
        imageCalculator("Subtract stack", "cyt01", "nv01");               // ... and outside the nucleus
        close("nucCol");
        // sums over the slices (2D images): reporter in the compartment (+ margin), voxel counts, products
        sumProduct("gfp", "md01", "sGMD"); sumProduct("gfp", "m01", "sGM");
        sumOf("m01", "sM"); sumOf("md01", "sMD"); sumOf("gfp", "sG");
        sumProduct("gfp", "cyt01", "sGC"); sumOf("cyt01", "sC"); sumProduct("gfp", "nv01", "sGN"); sumOf("nv01", "sN");
        if (!nuclear) { sumProduct("gfp", "gfp", "sGG"); sumProduct("tomraw", "tomraw", "sTT"); sumProduct("gfp", "tomraw", "sGT"); sumOf("tomraw", "sT"); }
        projectTo("gfp", "gmax");
        projectTo(cellSource, "cmax");
        // QC base: reporter green, compartment marker magenta (max projections)
        projectTo("tomraw", "tmax");
        selectWindow("gmax"); run("Duplicate...", "title=qg"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        selectWindow("tmax"); run("Duplicate...", "title=qt"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        run("Merge Channels...", "c2=qg c6=qt create");
        run("RGB Color"); rename("qc");
        close("Composite");
        if (cN > 0) drawOutline("qc", "nucmask", 0, 220, 255, false);
        for (ci = 0; ci < nCells; ci++) {
            cellSelect(ci);
            getSelectionBounds(bx, by, bw, bh);
            run("Select None");
            edge = false; if (bx <= 0 || by <= 0 || bx + bw >= W || by + bh >= H) edge = true;
            A = roiSum("nuc01", ci);                 // pixels of the cell (count) and of its nucleus
            nPix = A[0]; nucPix = A[1];
            if (cN > 0 && nucPix * pw * ph < minNuc) continue;   // no nucleus of its own: not a cell
            G = roiVal("sG", ci); GMD = roiVal("sGMD", ci); GM = roiVal("sGM", ci); Mv = roiVal("sM", ci); MD = roiVal("sMD", ci);
            // cytosol and nucleus (organelle import; the nucleus is the compartment in nuclear import)
            CytG = roiVal("sGC", ci); CytV = roiVal("sC", ci); NucG = roiVal("sGN", ci); NucV = roiVal("sN", ci);
            mitoMean = GM / Mv; cytMean = CytG / CytV; nucMean = NucG / NucV;
            if (nuclear) {
                rawFrac = GM / G;                    // share of the reporter in the nucleus: proteins diffuse into the
                frac = rawFrac;                      // nucleus, so its cytoplasmic level there is real (no subtraction)
                if (ringMode) { rawFrac = NaN; frac = NaN; }   // a ring is not the whole cell: no share of the cell
            } else {
                rawFrac = GMD / G;                   // all reporter light inside the outline (+ margin)
                frac = (GMD - cytMean * MD) / G;     // minus what the cytosolic level alone would put there
            }
            if (CytV <= 0) frac = NaN;
            ratio = mitoMean / cytMean; nucMito = nucMean / mitoMean;
            if (Mv == 0 || CytV <= 0) ratio = NaN;
            if (nuclear || cN == 0 || NucV <= 0 || Mv == 0) nucMito = NaN;
            pear = NaN;
            if (!nuclear) {
                nv = nz * nPix; GG = roiVal("sGG", ci); TT = roiVal("sTT", ci); GT = roiVal("sGT", ci); Ts = roiVal("sT", ci);
                pear = (GT - G * Ts / nv) / sqrt((GG - G * G / nv) * (TT - Ts * Ts / nv));
            }
            label = ci + 1;
            // (macro language: array functions need plain variables, not expressions, as arguments)
            imgNo = iCond.length; area = nPix * pw * ph; vol = Mv * pw * ph * pd;
            lev = roiVal("gmax", ci); lev = lev / nPix;
            mk = roiVal("cmax", ci); mk = mk / nPix;
            cImg = Array.concat(cImg, imgNo); cLabel = Array.concat(cLabel, label); cEdge = Array.concat(cEdge, edge);
            cArea = Array.concat(cArea, area); cLevel = Array.concat(cLevel, lev); cMarker = Array.concat(cMarker, mk);
            cFrac = Array.concat(cFrac, frac); cRatio = Array.concat(cRatio, ratio); cNuc = Array.concat(cNuc, nucMito); cPear = Array.concat(cPear, pear);
            cVol = Array.concat(cVol, vol); cRaw = Array.concat(cRaw, rawFrac);
            // QC: outline and number (excluded cells are marked once all cells are known)
            cellSelect(ci); selectWindow("qc"); run("Restore Selection");
            Roi.getBounds(lx, ly, lw, lh);
            setForegroundColor(255, 230, 0); run("Draw", "slice");
            run("Select None");
            setFont("SansSerif", maxOf(14, round(W / 45)), "bold antialiased");
            setColor(255, 255, 255); drawString("" + label, lx + lw / 2, ly + lh / 2);
            mx2 = lx + lw / 2; my2 = ly + lh / 2;
            cX = Array.concat(cX, mx2); cY = Array.concat(cY, my2);
        }
        iCond = Array.concat(iCond, fCond[fi]); iRep = Array.concat(iRep, fRep[fi]); iFile = Array.concat(iFile, name); iSer = Array.concat(iSer, s + 1);
        iBg = Array.concat(iBg, gBg); iNoise = Array.concat(iNoise, gNoise); iPx = Array.concat(iPx, pw); iNz = Array.concat(iNz, nz);
        qcFile = qcDir + qb + "_qc.png";
        iQc = Array.concat(iQc, qcFile); iW = Array.concat(iW, W);
        print(cname + " / " + name + ": " + nCells + " cell outline(s)");
        selectWindow("qc");
        saveAs("PNG", qcDir + qb + "_qc.png");
        close("*");
    }
}
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }
if (iCond.length == 0) exit("No image could be measured.\n" + skipped);
if (cImg.length == 0) exit("No cells were found. Check the channels (cell-fill marker, nuclei) and the qc/ images.\n" + skipped);

// ---- untransfected cells: reporter below minRel % of the median cell (all conditions); off for stained proteins ----
lv = newArray();
for (k = 0; k < cImg.length; k++) if (!(excludeEdge && cEdge[k])) lv = Array.concat(lv, cLevel[k]);
medLevel = NaN; if (lv.length > 0) medLevel = medianOf(lv);
cStatus = newArray(cImg.length);
for (k = 0; k < cImg.length; k++) {
    cStatus[k] = "measured";
    if (transfected && cLevel[k] < minRel / 100 * medLevel) cStatus[k] = "reporter too dim (untransfected)";
    if (excludeEdge && cEdge[k]) cStatus[k] = "cut by the image edge";
}
// image values = means of their measured cells; QC images get the excluded cells marked
cellRows = "Condition\tReplicate\tFile\tSeries\tCell\tStatus\tTouches edge\tArea (um2)\tReporter level\tReporter level (% of median cell)\tCell-marker level"
    + "\t" + fracName + "\t" + ratioName;
if (!nuclear) cellRows = cellRows + "\t" + nucName + "\tPearson (reporter vs marker)";
cellRows = cellRows + "\t" + orgShort + " volume (um3)\tReporter inside the outline, uncorrected\n";
iCells = newArray(iCond.length); iOut = newArray(iCond.length);
iFrac = newArray(iCond.length); iRatio = newArray(iCond.length); iNuc = newArray(iCond.length); iPear = newArray(iCond.length); iLevel = newArray(iCond.length);
for (i = 0; i < iCond.length; i++) {
    nMeas = 0; nOutCells = 0; sF = 0; sR = 0; sN = 0; sP = 0; sL = 0; nF = 0; nR = 0; nN = 0; nP = 0; marked = false;
    for (k = 0; k < cImg.length; k++) {
        if (cImg[k] != i) continue;
        eTxt = "no"; if (cEdge[k]) eTxt = "yes";
        cellRows = cellRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + cLabel[k] + "\t" + cStatus[k] + "\t" + eTxt
            + "\t" + d2s(cArea[k], 2) + "\t" + d2s(cLevel[k], 3) + "\t" + d2s(100 * cLevel[k] / medLevel, 1) + "\t" + d2s(cMarker[k], 3)
            + "\t" + d2s(cFrac[k], 4) + "\t" + d2s(cRatio[k], 4);
        if (!nuclear) cellRows = cellRows + "\t" + d2s(cNuc[k], 4) + "\t" + d2s(cPear[k], 4);
        cellRows = cellRows + "\t" + d2s(cVol[k], 3) + "\t" + d2s(cRaw[k], 4) + "\n";
        if (cStatus[k] != "measured") {
            nOutCells++;
            if (!marked) { open(iQc[i]); marked = true; }
            setFont("SansSerif", maxOf(12, round(iW[i] / 60)), "bold antialiased");
            setColor(160, 160, 160); drawString("excluded", cX[k] - getStringWidth("excluded") / 2, cY[k] + maxOf(16, round(iW[i] / 40)));
            continue;
        }
        nMeas++; sL += cLevel[k];
        if (!isNaN(cFrac[k])) { sF += cFrac[k]; nF++; }
        if (!isNaN(cRatio[k])) { sR += cRatio[k]; nR++; }
        if (!isNaN(cNuc[k])) { sN += cNuc[k]; nN++; }
        if (!isNaN(cPear[k])) { sP += cPear[k]; nP++; }
    }
    if (marked) { saveAs("PNG", iQc[i]); close(); }
    iCells[i] = nMeas; iOut[i] = nOutCells;
    iFrac[i] = NaN; if (nF > 0) iFrac[i] = sF / nF;
    iRatio[i] = NaN; if (nR > 0) iRatio[i] = sR / nR;
    iNuc[i] = NaN; if (nN > 0) iNuc[i] = sN / nN;
    iPear[i] = NaN; if (nP > 0) iPear[i] = sP / nP;
    iLevel[i] = NaN; if (nMeas > 0) iLevel[i] = sL / nMeas;
    print(condNames[iCond[i]] + " / " + iFile[i] + ": " + nMeas + " cells measured (" + nOutCells + " excluded), " + toLowerCase(fracName) + " " + d2s(iFrac[i], 3)
        + ", " + ratioName + " " + d2s(iRatio[i], 2));
}

// ---- 5. tables ----
useReps = compare;
for (c = 0; c < nCond; c++) if (repCount(iRep, iCond, c) < 2) useReps = false;
unitName = "images"; if (useReps) unitName = "replicates";
readouts = newArray(fracName, ratioName, nucName, "Pearson (reporter vs marker)", "Reporter level", "Cells measured");
graphed = newArray(0, 1, 2, 3);
if (nuclear) graphed = newArray(0, 1);
if (ringMode) { graphed = newArray(1); graphed[0] = 1; }
summary = "Readout\tCondition\tMean\tSD\tn (" + unitName + ")";
if (compare) summary = summary + "\tRelative to " + condNames[0] + "\tChange vs " + condNames[0] + " (%)";
summary = summary + "\n";
graphs = newArray();
for (k = 0; k < readouts.length; k++) {
    if (nuclear && (k == 2 || k == 3)) continue;
    if (ringMode && k == 0) continue;
    if (k == 0) v = iFrac; if (k == 1) v = iRatio; if (k == 2) v = iNuc; if (k == 3) v = iPear; if (k == 4) v = iLevel; if (k == 5) v = iCells;
    gMean = newArray(nCond); gSd = newArray(nCond); px = newArray(); py = newArray();
    for (c = 0; c < nCond; c++) {
        pts = unitValues(v, iCond, iRep, c, useReps);
        gm = NaN; gs = NaN;
        if (pts.length > 0) Array.getStatistics(pts, mn, mx, gm, gs);
        if (pts.length < 2) gs = NaN;
        gMean[c] = gm; gSd[c] = gs;
        for (i = 0; i < pts.length; i++) { px = Array.concat(px, c + 0.25 * (i - (pts.length - 1) / 2) / maxOf(1, pts.length - 1)); py = Array.concat(py, pts[i]); }
        summary = summary + readouts[k] + "\t" + condNames[c] + "\t" + d2s(gm, 4) + "\t" + d2s(gs, 4) + "\t" + pts.length;
        if (compare) summary = summary + "\t" + d2s(gm / gMean[0], 4) + "\t" + d2s(100 * (gm / gMean[0] - 1), 2);
        summary = summary + "\n";
    }
    isGraphed = false; for (i = 0; i < graphed.length; i++) if (graphed[i] == k) isGraphed = true;
    if (compare && isGraphed) {
        gFile = outDir + "bar_" + k + ".png";
        gFile = barGraph(readouts[k], condNames, gMean, gSd, px, py, unitName, gFile);
        graphs = Array.concat(graphs, gFile);
    }
}
imgRows = "Condition\tReplicate\tFile\tSeries\tCells measured\tCells excluded\t" + fracName + "\t" + ratioName;
if (!nuclear) imgRows = imgRows + "\t" + nucName + "\tPearson (reporter vs marker)";
imgRows = imgRows + "\tReporter level\tReporter background\tBackground noise\tPixel size (um)\tSlices\n";
for (i = 0; i < iCond.length; i++) {
    imgRows = imgRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + iCells[i] + "\t" + iOut[i] + "\t" + d2s(iFrac[i], 4) + "\t" + d2s(iRatio[i], 4);
    if (!nuclear) imgRows = imgRows + "\t" + d2s(iNuc[i], 4) + "\t" + d2s(iPear[i], 4);
    imgRows = imgRows + "\t" + d2s(iLevel[i], 3) + "\t" + d2s(iBg[i], 3) + "\t" + d2s(iNoise[i], 3) + "\t" + d2s(iPx[i], 4) + "\t" + iNz[i] + "\n";
}
repRows = "Condition\tReplicate\tImages\tCells measured\t" + fracName + "\t" + ratioName;
if (!nuclear) repRows = repRows + "\t" + nucName + "\tPearson (reporter vs marker)";
repRows = repRows + "\n";
for (c = 0; c < nCond; c++) {
    reps = newArray();
    for (i = 0; i < iCond.length; i++) if (iCond[i] == c) reps = Array.concat(reps, iRep[i]);
    reps = uniqueOf(reps);
    for (r = 0; r < reps.length; r++) {
        nn = 0; nc = 0;
        for (i = 0; i < iCond.length; i++) if (iCond[i] == c) { if (iRep[i] == reps[r]) { nn++; nc += iCells[i]; } }
        repRows = repRows + condNames[c] + "\t" + reps[r] + "\t" + nn + "\t" + nc + "\t" + d2s(repMean(iFrac, iCond, iRep, c, reps[r]), 4)
            + "\t" + d2s(repMean(iRatio, iCond, iRep, c, reps[r]), 4);
        if (!nuclear) repRows = repRows + "\t" + d2s(repMean(iNuc, iCond, iRep, c, reps[r]), 4) + "\t" + d2s(repMean(iPear, iCond, iRep, c, reps[r]), 4);
        repRows = repRows + "\n";
    }
}
settings = "Setting\tValue\nPlugin\tConfocal Workflows " + pluginVersion() + "\nImport into\t" + target + "\nReporter\t" + reporterType + "\nAnalysis\t" + mode + "\n";
if (compare) for (g = 0; g < nCond; g++) settings = settings + condNames[g] + " folder\t" + dirs[g] + "\n";
else settings = settings + "Input\t" + fPath[0] + "\n";
settings = settings + "Reporter channel\t" + gfpCh + "\nNuclei\t" + nucCh + "\nCell-fill marker\t" + cellCh;
if (!nuclear) settings = settings + "\n" + orgShort + " marker\t" + mitoCh;
if (nuclear && cC == 0) settings = settings + "\nCells\tnucleus + a " + ring + " um ring around it, split halfway between nuclei (Voronoi; nuclei: " + nucMethod + " threshold); minimum " + minCell + " um2";
else settings = settings + "\nCells\tcell-fill marker (or reporter) max projection, Gaussian 1 um, " + cellMethod + " threshold, holes filled; split halfway between nuclei (Voronoi; nuclei: " + nucMethod + " threshold); a cell needs >= " + minNuc + " um2 of its own nucleus inside; minimum " + minCell + " um2";
if (transfected) settings = settings + "\nUntransfected cells\treporter level (mean of the max projection in the cell, background subtracted) below " + minRel + "% of the median cell of all images (" + d2s(medLevel, 2) + "): listed, not measured";
else settings = settings + "\nUntransfected cells\tnot applied (endogenous stained protein: every cell measured)";
settings = settings + "\nCells cut by the image edge\t"; if (excludeEdge) settings = settings + "excluded"; else settings = settings + "measured and flagged (readouts are ratios within the visible part)";
settings = settings
    + "\nCells in 3D\tthe cell-fill marker (or the reporter) with a 3D Gaussian (1 um, 1 slice) and Otsu (whole stack) in every slice: cytosol and nucleus voxels are counted only inside the cell, not above or below a thin cytoplasm"
    + "\nReporter background\tmedian of the reporter outside the cells (outline widened by 2 um), over the slices; subtracted (no rolling ball: the diffuse cytosolic reporter is the signal)";
if (nuclear) settings = settings
    + "\nNucleus\tDAPI outline (max projection, Gaussian 0.5 um, " + nucMethod + ", holes filled) through the slices; a " + margin + " um gap around it (" + rpx + " pixel(s)) is left out of the cytoplasm"
    + "\n" + fracName + "\treporter in the nucleus / reporter in the whole cell (no subtraction: proteins diffuse into the nucleus, so the cytoplasmic level there is real); not reported without a cell-fill marker (the ring is not the whole cell)"
    + "\n" + ratioName + "\tmean reporter in the nucleus / mean reporter in the cytoplasm (cell outside the nucleus + gap), over the slices";
else settings = settings
    + "\n" + orgShort + "\tmarker prepared per slice (rolling ball " + bgRadius + " um, 1-pixel Gaussian, remaining background = median below Otsu set to 0), threshold " + T + " (" + method + "; methods scored on " + nRef + " " + condNames[0] + " image(s), applied unchanged to all slices of all images)"
    + "\nMargin\tthe " + orgLow + " outline widened by " + margin + " um (" + rpx + " pixel(s) at the last image's pixel size) for the reporter's blur"
    + "\n" + fracName + "\t(reporter in " + orgLow + " + margin - mean cytosolic reporter x their volume) / reporter in the whole cell, over the slices: the share of the reporter above the cytosolic level. Blur spreads cytosolic light into the outline; subtracting the cytosolic level removes most of it (the uncorrected share is in the Cells sheet). Deconvolved stacks give values closer to the truth"
    + "\n" + ratioName + "\tmean reporter in " + orgLow + " (no margin) / mean reporter in the cytosol (cell outside " + orgLow + " + margin and outside the nucleus), over the slices"
    + "\n" + nucName + "\tmean reporter in the nucleus (outside " + orgLow + " + margin) / mean reporter in " + orgLow + "; the nucleus outline is applied to every slice"
    + "\nPearson\treporter vs background-subtracted marker over every voxel of the cell (no threshold)";
settings = settings + "\nStatistics unit\t" + unitName + " (image value = mean of its measured cells)\nImages measured\t" + iCond.length + "\n";
xlsx = outDir + "protein_import_results.xlsx";
if (nuclear) err = writeXlsx(xlsx, newArray("Summary", "Replicates", "Images", "Cells", "Settings"), newArray(summary, repRows, imgRows, cellRows, settings));
else err = writeXlsx(xlsx, newArray("Summary", "Replicates", "Images", "Cells", "Threshold methods", "Settings"), newArray(summary, repRows, imgRows, cellRows, methodRows, settings));
if (err != "") print("Excel file could not be written: " + err);
if (graphs.length > 0) {
    for (i = 0; i < graphs.length; i++) open(graphs[i]);
    run("Images to Stack", "method=[Copy (center)] name=graphs title=bar_ use");
    run("Make Montage...", "columns=" + minOf(4, graphs.length) + " rows=" + Math.ceil(graphs.length / 4) + " scale=1 border=0");
    saveAs("PNG", outDir + "bar_graphs.png");
    close("*");
    for (i = 0; i < graphs.length; i++) ok = File.delete(graphs[i]);
}
setBatchMode(false);
total = 0; for (i = 0; i < iCells.length; i++) total += iCells[i];
done = "Measured " + total + " cells in " + iCond.length + " images (" + target + ")";
if (!nuclear) done = done + "; " + orgLow + " threshold " + d2s(T, 2) + " (" + method + ")";
done = done + ".\n \nResults:  " + xlsx;
if (graphs.length > 0) done = done + "\nBar graphs:  " + outDir + "bar_graphs.png";
done = done + "\nQC images:  " + qcDir + "\n \nStatistics use " + unitName + ", not pooled cells.";
if (noBgList != "") done = done + "\n \nLittle cell-free background (under 2% of the field), so the reporter background is less certain in:\n" + noBgList;
if (skipped != "") done = done + "\n \nNot processed:\n" + skipped + "A file listed here that should match the others is most likely damaged.";
if (graphs.length > 0 && interactive) open(outDir + "bar_graphs.png");
print("Done. " + done);
if (interactive) showMessage("Protein import finished", done);

// ================= functions =================


// ======== shared functions: copied from lib/common.ijm by tools/build.py; edit them there, not here ========

// Reads series and channel metadata through Bio-Formats (OME model) inside try/catch, or a single 'E<tab>error'
// line for an unreadable file. One tab-separated line per series and per channel:
//   S  series  name  sizeX  sizeZ  sizeC  pixel_um  zstep_um  NA  refractive_index  sizeT  readable(1/0)  rgb_channels  immersion
//   C  series  channel  name (display colour and excitation, e.g. "CH2 (green 488 nm)")  excitation_nm  emission_nm
// Unknown numbers are -1.
function readMetadata(path) {
    p = jsText(path);
    js = "importClass(Packages.loci.formats.ImageReader); importClass(Packages.loci.formats.MetadataTools);"
       + "var U = Packages.ome.units.UNITS;"
       + "function len(q, u) { return q == null ? -1 : q.value(u).doubleValue(); }"
       + "function tryget(f) { try { return f(); } catch (e) { return null; } }"
       + "var r = new ImageReader(); var m = MetadataTools.createOMEXMLMetadata(); r.setMetadataStore(m); var out = [];"
       + "try { r.setId('" + p + "');"
       + "for (var s = 0; s < r.getSeriesCount(); s++) { r.setSeries(s);"
       + "  var ok = 1; try { r.openBytes(r.getImageCount() - 1); } catch (e) { ok = 0; }"
       + "  var nm = tryget(function () { return m.getImageName(s); }); if (nm == null) nm = 'Series' + (s + 1);"
       + "  var id = tryget(function () { return m.getObjectiveSettingsID(s); }); var na = -1, imm = '';"
       + "  for (var i = 0; i < m.getInstrumentCount(); i++) for (var o = 0; o < m.getObjectiveCount(i); o++) {"
       + "    var v = tryget(function () { return m.getObjectiveLensNA(i, o); });"
       + "    var match = id != null && String(m.getObjectiveID(i, o)) == String(id);"
       + "    if (v != null && (na < 0 || match)) { na = v; var im = tryget(function () { return m.getObjectiveImmersion(i, o); }); imm = im == null ? '' : String(im); } }"
       + "  var ri = tryget(function () { return m.getObjectiveSettingsRefractiveIndex(s); }); if (ri == null) ri = -1;"
       + "  out.push(['S', s, String(nm).replace(/[\\t\\n]/g, ' '), r.getSizeX(), r.getSizeZ(), r.getSizeC(),"
       + "    len(tryget(function () { return m.getPixelsPhysicalSizeX(s); }), U.MICROMETER),"
       + "    len(tryget(function () { return m.getPixelsPhysicalSizeZ(s); }), U.MICROMETER), na, ri, r.getSizeT(), ok, r.getRGBChannelCount(), imm].join('\\t'));"
       + "  for (var c = 0; c < r.getSizeC(); c++) {"
       + "    var cn = tryget(function () { return m.getChannelName(s, c); }); cn = cn == null ? 'C' + (c + 1) : String(cn).replace(/[\\t\\n,]/g, ' ');"
       + "    var col = tryget(function () { return m.getChannelColor(s, c); }), cname = '';"
       + "    if (col != null) { var R = col.getRed() > 100, G = col.getGreen() > 100, B = col.getBlue() > 100;"
       + "      cname = R && G && B ? 'grey' : R && G ? 'yellow' : R && B ? 'magenta' : G && B ? 'cyan' : R ? 'red' : G ? 'green' : B ? 'blue' : ''; }"
       + "    var ex = len(tryget(function () { return m.getChannelExcitationWavelength(s, c); }), U.NANOMETER);"
       + "    var em = len(tryget(function () { return m.getChannelEmissionWavelength(s, c); }), U.NANOMETER);"
       + "    var tag = []; if (cname != '') tag.push(cname); if (ex > 0) tag.push(Math.round(ex) + ' nm');"
       + "    if (tag.length > 0) cn = cn + ' (' + tag.join(' ') + ')';"
       + "    out.push(['C', s, c, cn, ex, em].join('\\t')); } }"
       + "} catch (e) { out = ['E\\t' + String(e).replace(/[\\t\\n]/g, ' ')]; }"
       + "try { r.close(); } catch (e) {} out.join('\\n');";
    return eval("js", js);
}

// text as the inside of a JavaScript '...' string: every backslash and quote escaped one by one (macro replace()
// treats a one-character pattern literally, so a regular-expression escape doubles the backslash).
function jsText(s) {
    out = "";
    for (i = 0; i < lengthOf(s); i++) { c = substring(s, i, i + 1); if (c == "\\" || c == "'") out = out + "\\"; out = out + c; }
    return out;
}

// Files Bio-Formats opens as microscope data (subfolders and hidden files skipped).
function isMicroscopeFile(name) {
    n = toLowerCase(name);
    if (endsWith(n, "/") || startsWith(n, ".")) return false;
    ext = newArray(".oir", ".oib", ".oif", ".czi", ".lsm", ".lif", ".lof", ".nd2", ".ims", ".vsi", ".zvi", ".dv", ".ics", ".tif", ".tiff");
    for (i = 0; i < ext.length; i++) if (endsWith(n, ext[i])) return true;
    return false;
}

// The readable part of a Java error: no exception class name, no file path.
function shortError(e, path) {
    e = replace(e, "^.*Exception: ", "");
    if (endsWith(e, File.getName(path)) && lastIndexOf(e, ": ") > 0) e = substring(e, 0, lastIndexOf(e, ": "));
    return e;
}

// Opens series s (0-based) as a hyperstack through Bio-Formats' API inside try/catch; returns "" or the error.
function openSeries(path, s) {
    p = jsText(path);
    js = "var I = Packages.loci.plugins['in'].ImporterOptions; var o = new I(); o.setId('" + p + "');"
       + "o.setColorMode(I.COLOR_MODE_DEFAULT); o.setStackOrder(I.ORDER_XYCZT); o.setQuiet(true); o.setOpenAllSeries(false);"
       + "o.setSeriesOn(0, false); o.setSeriesOn(" + s + ", true);"
       + "var err = ''; try { Packages.loci.plugins.BF.openImagePlus(o)[0].show(); } catch (e) { err = String(e); } err;";
    return eval("js", js);
}

function sameFolder(a, b) {
    a = replace(a, "\\\\", "/"); b = replace(b, "\\\\", "/");
    if (!endsWith(a, "/")) a = a + "/";
    if (!endsWith(b, "/")) b = b + "/";
    if (startsWith(getInfo("os.name"), "Windows")) { a = toLowerCase(a); b = toLowerCase(b); }
    if (a == b) return true;
    return false;
}

function sanitize(name) {
    return replace(name, "[^a-zA-Z0-9._-]", "_");
}

// Indices of the series to measure in a file (full-size, not time-lapse, readable); -1 = unreadable file,
// -2 = series excluded (pyramid level / time-lapse / unreadable plane).
function usableSeries(path) {
    lines = split(readMetadata(path), "\n");
    if (startsWith(lines[0], "E")) { bad = newArray(1); bad[0] = -1; return bad; }
    sx = newArray(); st = newArray(); sok = newArray();
    for (i = 0; i < lines.length; i++) {
        f = split(lines[i], "\t");
        if (f[0] != "S") continue;
        k = parseInt(f[1]); sx[k] = parseInt(f[3]); st[k] = parseInt(f[10]); sok[k] = parseInt(f[11]);
    }
    maxX = 0;
    for (k = 0; k < sx.length; k++) maxX = maxOf(maxX, sx[k]);
    out = newArray();
    for (k = 0; k < sx.length; k++) {
        if (sx[k] < maxX / 2 || st[k] > 1 || sok[k] == 0) out = Array.concat(out, -2);
        else out = Array.concat(out, k);
    }
    return out;
}

function uniqueOf(a) {
    out = newArray();
    for (i = 0; i < a.length; i++) {
        seen = false;
        for (j = 0; j < out.length; j++) if (out[j] == a[i]) seen = true;
        if (!seen) out = Array.concat(out, a[i]);
    }
    return out;
}

function medianOf(a) {
    b = Array.copy(a); Array.sort(b);
    n = b.length;
    if (n % 2 == 1) return b[floor(n / 2)];
    return (b[n / 2 - 1] + b[n / 2]) / 2;
}

// Microscope files in dir and in its subfolders (one level; the subfolder name is the replicate): "rep<tab>path".
// Output folders of these workflows (deconvolved, qc, figures) are not replicates and are skipped.
function collect(dir) {
    out = newArray();
    list = getFileList(dir); Array.sort(list);
    for (i = 0; i < list.length; i++) {
        lower = toLowerCase(list[i]);
        if (lower == "deconvolved/" || lower == "qc/" || lower == "figures/") continue;
        if (endsWith(list[i], "/")) {
            rep = substring(list[i], 0, lengthOf(list[i]) - 1);
            inner = getFileList(dir + list[i]); Array.sort(inner);
            for (j = 0; j < inner.length; j++) if (isMicroscopeFile(inner[j])) out = Array.concat(out, rep + "\t" + dir + list[i] + inner[j]);
        } else if (isMicroscopeFile(list[i])) out = Array.concat(out, "-\t" + dir + list[i]);
    }
    return out;
}

function folderName(dir) {
    d = replace(dir, "\\\\", "/");
    if (endsWith(d, "/")) d = substring(d, 0, lengthOf(d) - 1);
    return File.getName(d);
}

function countOf(a, x) {
    n = 0;
    for (i = 0; i < a.length; i++) if (a[i] == x) n++;
    return n;
}

// Number of real replicate subfolders (not "-") among the measured images of condition c.
function repCount(iRep, iCond, c) {
    reps = newArray();
    for (i = 0; i < iCond.length; i++) if (iCond[i] == c) { if (iRep[i] != "-") reps = Array.concat(reps, iRep[i]); }
    reps = uniqueOf(reps);
    return reps.length;
}

// The statistical units of condition c: replicate means (useReps) or image values; NaN skipped.
function unitValues(v, iCond, iRep, c, useReps) {
    out = newArray();
    if (!useReps) {
        for (i = 0; i < v.length; i++) if (iCond[i] == c) { if (!isNaN(v[i])) out = Array.concat(out, v[i]); }
        return out;
    }
    reps = newArray();
    for (i = 0; i < v.length; i++) if (iCond[i] == c) reps = Array.concat(reps, iRep[i]);
    reps = uniqueOf(reps);
    for (r = 0; r < reps.length; r++) {
        sum = 0; n = 0;
        for (i = 0; i < v.length; i++) if (iCond[i] == c) { if (iRep[i] == reps[r] && !isNaN(v[i])) { sum += v[i]; n++; } }
        if (n > 0) out = Array.concat(out, sum / n);
    }
    return out;
}

// Mean of v over the images of condition c and replicate rep (NaN skipped).
function repMean(v, iCond, iRep, c, rep) {
    sum = 0; n = 0;
    for (i = 0; i < v.length; i++) if (iCond[i] == c) { if (iRep[i] == rep && !isNaN(v[i])) { sum += v[i]; n++; } }
    if (n == 0) return NaN;
    return sum / n;
}

// Scores threshold T on one background-subtracted image's histogram (bins off .. off+nb-1 of hv/hc).
// Background noise is symmetric around 0, so the pixels below -T estimate the noise pixels above +T.
//   noise  = (pixels <= -T) / (pixels >= T)              share of the positive pixels that are noise
//   signal = (sum of x >= T + sum of x <= -T) / sum of x  share of the net signal kept (noise sums to ~0)
//   score  = signal * (1 - noise)
// Returns [score, % positive area, signal, noise].
function scoreThreshold(hv, hc, off, nb, T) {
    N = 0; tot = 0; nF = 0; nN = 0; cap = 0;
    half = (hv[off + 1] - hv[off]) / 2;
    for (i = off; i < off + nb; i++) {
        x = hv[i] + half; c = hc[i];
        N += c; tot += c * x;
        if (x >= T) { nF += c; cap += c * x; }
        if (x <= -T) { nN += c; cap += c * x; }
    }
    if (T <= 0 || nF == 0 || tot <= 0) return newArray(0, 100 * nF / N, 0, 1);
    noise = minOf(1, nN / nF);
    signal = minOf(1, maxOf(0, cap / tot));
    return newArray(signal * (1 - noise), 100 * nF / N, signal, noise);
}

// Live threshold window for the image "preview" (titled title): the yellow outlines follows the typed value, the slider and the
// method list. Returns "value<tab>index of the chosen method<tab>1 if the value was edited, else 0" (an unedited
// value is the method's exact threshold, not the rounded one the field shows), "cancel", or "ERR ...".
function thresholdDialog(title, msg, labels, vals, maxV) {
    l = ""; v = "";
    for (i = 0; i < labels.length; i++) { l = l + replace(labels[i], "['|]", "") + "|"; v = v + d2s(vals[i], 9) + ","; }
    msg = replace(msg, "'", ""); title = replace(title, "'", "");
    msg = replace(msg, "\n", "\\n");
    js = "try { var imp = Packages.ij.WindowManager.getImage('preview'); var L = '" + l + "'.split('|'); L.pop(); var vals = [" + v + "];"
       + "var gd = new Packages.ij.gui.NonBlockingGenericDialog('" + title + "');"
       + "gd.addMessage('" + msg + "');"
       + "gd.addChoice('Method', L, L[0]);"
       + "gd.addSlider('Threshold', 0, " + maxV + ", vals[0], " + (maxV / 1000) + ");"
       + "var cur = vals[0], last = imp.getCurrentSlice();"
       + "function show(t) { cur = t; var ip = imp.getProcessor(); ip.setThreshold(t, 1e30, Packages.ij.process.ImageProcessor.NO_LUT_UPDATE);"
       + "  var roi = new Packages.ij.plugin.filter.ThresholdToSelection().convert(ip); ip.resetThreshold(); var ov = new Packages.ij.gui.Overlay();"
       + "  if (roi != null) { roi.setStrokeColor(java.awt.Color.YELLOW); ov.add(roi); } imp.setOverlay(ov); }"
       + "var lis = new Packages.ij.ImageListener({ imageOpened: function (i) {}, imageClosed: function (i) {},"
       + "  imageUpdated: function (i) { if (i == imp && imp.getCurrentSlice() != last) { last = imp.getCurrentSlice(); show(cur); } } });"
       + "Packages.ij.ImagePlus.addImageListener(lis); show(vals[0]);"
       + "gd.addDialogListener(new Packages.ij.gui.DialogListener({ dialogItemChanged: function (g, e) {"
       + "  var ch = g.getChoices().get(0); var tf = g.getNumericFields().get(0);"
       + "  if (e != null && e.getSource() == ch) tf.setText(String(vals[ch.getSelectedIndex()]));"
       + "  var t = parseFloat(tf.getText()); if (!isNaN(t)) show(t); return true; } }));"
       + "var w = imp.getWindow(); var ss = java.awt.Toolkit.getDefaultToolkit().getScreenSize(); var sw = ss.width, sh = ss.height;"
       + "if (w != null) { var z = Math.min(1, Math.min(0.55 * sw / imp.getWidth(), 0.8 * sh / imp.getHeight()));"
       + "  var cv = imp.getCanvas(); var guard = 0; while (cv.getMagnification() > z + 1e-6 && guard++ < 20) cv.zoomOut(Math.floor(imp.getWidth() / 2), Math.floor(imp.getHeight() / 2));"
       + "  w = imp.getWindow(); w.setLocation(0, 0); gd.pack(); gd.centerDialog(false); gd.setLocation(Math.max(0, Math.min(w.getWidth() + 10, sw - gd.getWidth())), 0); }"
       + "gd.showDialog(); var out = 'cancel';"
       + "if (!gd.wasCanceled()) { var k = gd.getNextChoiceIndex(), t = gd.getNextNumber();"
       + "  var edited = Math.abs(t - vals[k]) > " + (maxV / 1000) + ";"   // the field shows a rounded value: within a step = unchanged
       + "  out = (edited ? t : vals[k]) + '\\t' + k + '\\t' + (edited ? 1 : 0); }"
       + "Packages.ij.ImagePlus.removeImageListener(lis); imp.setOverlay(null); out; } catch (e) { 'ERR ' + e; }";
    return eval("js", js);
}

// Bar graph (mean, SD error bars, one dot per statistical unit) of the conditions, saved as a PNG; returns its path.
function barGraph(title, names, means, sds, px, py, unitName, file) {
    hi = 0; lo = 0;
    for (i = 0; i < py.length; i++) { hi = maxOf(hi, py[i]); lo = minOf(lo, py[i]); }
    e = newArray(sds.length);
    for (i = 0; i < sds.length; i++) { e[i] = sds[i]; if (isNaN(e[i])) e[i] = 0; hi = maxOf(hi, means[i] + e[i]); }
    n = names.length;
    Plot.create("bar_" + title, "{" + String.join(names, ",") + "}", title);
    Plot.setLimits(-0.6, n - 0.4, lo * 1.15, hi * 1.15);
    Plot.setFrameSize(maxOf(260, 110 * n), 260);
    Plot.setColor("#12294A", "#9DB4D6");
    Plot.add("separated bar", Array.getSequence(n), means);
    Plot.setColor("black");
    Plot.add("error bars", e);
    Plot.setColor("#E2552D", "#E2552D");
    Plot.add("circle", px, py);
    Plot.setColor("black");
    Plot.addText("mean +/- SD; dots = " + unitName, 0.02, 0.06);
    Plot.show();
    saveAs("PNG", file);
    close();
    return file;
}

// Writes tab-separated tables as the sheets of an .xlsx workbook (numbers as numbers, header row frozen).
// Returns "" or the error.
function writeXlsx(path, names, contents) {
    tmp = getDirectory("temp");
    files = "";
    for (i = 0; i < names.length; i++) {
        f = tmp + "sheet" + i + ".tsv";
        File.saveString(contents[i], f);
        files = files + jsText(f) + "|";
        names[i] = replace(names[i], "[|'\\[\\]:*?/\\\\]", " ");
    }
    p = jsText(path);
    js = "try { var Z = java.util.zip; var out = new Z.ZipOutputStream(new java.io.FileOutputStream('" + p + "'));"
       + "function put(n, t) { out.putNextEntry(new Z.ZipEntry(n)); var b = new java.lang.String(t).getBytes('UTF-8'); out.write(b, 0, b.length); out.closeEntry(); }"
       + "function esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\"/g, '&quot;'); }"
       + "function col(i) { var s = ''; i++; while (i > 0) { var m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); } return s; }"
       + "var names = '" + String.join(names, "|") + "'.split('|'); var files = '" + files + "'.split('|');"
       + "var NS = 'http://schemas.openxmlformats.org/'; var ct = '', wb = '', rel = '';"
       + "for (var s = 0; s < names.length; s++) {"
       + "  var lines = java.nio.file.Files.readAllLines(java.nio.file.Paths.get(files[s]), java.nio.charset.StandardCharsets.UTF_8); var rows = [];"
       + "  for (var r = 0; r < lines.size(); r++) { var f = String(lines.get(r)).split('\\t'); var cells = [];"
       + "    for (var c = 0; c < f.length; c++) { var x = f[c], ref = col(c) + (r + 1);"
       + "      if (x == '' || x == 'NaN') continue;"
       + "      if (/^-?[0-9]+(\\.[0-9]+)?([eE]-?[0-9]+)?$/.test(x)) cells.push('<c r=\"' + ref + '\"><v>' + x + '</v></c>');"
       + "      else cells.push('<c r=\"' + ref + '\" t=\"inlineStr\"><is><t>' + esc(x) + '</t></is></c>'); }"
       + "    rows.push('<row r=\"' + (r + 1) + '\">' + cells.join('') + '</row>'); }"
       + "  put('xl/worksheets/sheet' + (s + 1) + '.xml', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"' + NS + 'spreadsheetml/2006/main\">'"
       + "    + '<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>'"
       + "    + '<cols><col min=\"1\" max=\"30\" width=\"18\" customWidth=\"1\"/></cols><sheetData>' + rows.join('') + '</sheetData></worksheet>');"
       + "  ct += '<Override PartName=\"/xl/worksheets/sheet' + (s + 1) + '.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>';"
       + "  wb += '<sheet name=\"' + esc(names[s]) + '\" sheetId=\"' + (s + 1) + '\" r:id=\"rId' + (s + 1) + '\"/>';"
       + "  rel += '<Relationship Id=\"rId' + (s + 1) + '\" Type=\"' + NS + 'officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet' + (s + 1) + '.xml\"/>'; }"
       + "put('[Content_Types].xml', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"' + NS + 'package/2006/content-types\">'"
       + "  + '<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>'"
       + "  + '<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>' + ct + '</Types>');"
       + "put('_rels/.rels', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"' + NS + 'package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"' + NS + 'officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>');"
       + "put('xl/workbook.xml', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"' + NS + 'spreadsheetml/2006/main\" xmlns:r=\"' + NS + 'officeDocument/2006/relationships\"><sheets>' + wb + '</sheets></workbook>');"
       + "put('xl/_rels/workbook.xml.rels', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"' + NS + 'package/2006/relationships\">' + rel + '</Relationships>');"
       + "out.close(); ''; } catch (e) { String(e); }";
    err = eval("js", js);
    for (i = 0; i < names.length; i++) { f = tmp + "sheet" + i + ".tsv"; if (File.exists(f)) ok = File.delete(f); }
    return err;
}

// 1-based channel number of a choice "C<n> name", 0 for a "None ..." choice.
function chIndex(choice) {
    if (startsWith(choice, "None")) return 0;
    return parseInt(substring(choice, 1, indexOf(choice, " ")));
}

// Index (0-based) of the first channel whose name matches the regular expression (case-insensitive), else dflt.
function channelLike(names, re, dflt) {
    for (i = 0; i < names.length; i++) if (matches(toLowerCase(names[i]), ".*(" + re + ").*")) return i;
    return dflt;
}

// Opens series s and keeps the given channels (1-based) as 32-bit images or stacks with the given titles
// (calibration kept). Returns "" or the problem.
function loadChannels(path, s, chs, titles) {
    err = openSeries(path, s);
    if (err != "") return "could not be opened (" + shortError(err, path) + ")";
    src = getTitle();
    getDimensions(w, h, c, z, t);
    for (i = 0; i < chs.length; i++) if (c < chs[i]) { close(src); return "has only " + c + " channel(s)"; }
    getPixelSize(unit, pw, ph);
    if (unit == "pixel" || unit == "pixels" || unit == "") { close(src); return "has no pixel size (uncalibrated: set it in Image > Properties and save, or use the original microscope file)"; }
    for (i = 0; i < chs.length; i++) {
        selectWindow(src);
        run("Duplicate...", "title=" + titles[i] + " duplicate channels=" + chs[i]);
        run("32-bit");
    }
    close(src);
    return "";
}

// Max projection of title (a copy when it is a single plane) named newTitle.
function projectTo(title, newTitle) {
    selectWindow(title);
    if (nSlices > 1) run("Z Project...", "projection=[Max Intensity]");
    else run("Duplicate...", " ");
    rename(newTitle);
}

// Sum over the slices of title (32-bit, 2D) named newTitle.
function sumOf(title, newTitle) {
    selectWindow(title);
    if (nSlices > 1) run("Z Project...", "projection=[Sum Slices]");
    else run("Duplicate...", " ");
    rename(newTitle);
}

// Sum over the slices of title1 x title2, named newTitle.
function sumProduct(title1, title2, newTitle) {
    imageCalculator("Multiply create 32-bit stack", title1, title2);
    rename("prod_tmp");
    sumOf("prod_tmp", newTitle);
    close("prod_tmp");
}

// Prepares title (image or stack) for outlining: rolling ball, 1-pixel Gaussian, remaining background
// (median of the pixels below the Otsu threshold, over all slices) subtracted. Returns that background.
function prepare(title, radiusUm) {
    selectWindow(title);
    getPixelSize(unit, pw, ph);
    r = maxOf(2, radiusUm / pw);
    flag = ""; if (nSlices > 1) flag = " stack";
    run("Subtract Background...", "rolling=" + r + flag);
    run("Gaussian Blur...", "sigma=1" + flag);
    setAutoThreshold("Otsu dark stack");
    getThreshold(lo, hi);
    sum = 0; n = 0;
    for (z = 1; z <= nSlices; z++) {
        setSlice(z);
        setThreshold(-1e30, lo);
        run("Create Selection");
        if (selectionType() >= 0) {
            getRawStatistics(nb);
            List.setMeasurements;
            sum += nb * List.getValue("Median"); n += nb;
        }
        run("Select None");
    }
    resetThreshold();
    setSlice(1);
    bg = 0; if (n > 0) bg = sum / n;
    run("Subtract...", "value=" + bg + flag);
    return bg;
}

// Draws the white pixels of mask (single plane) onto the RGB image target in the given colour: their outline,
// or the pixels themselves (fillIt, for a skeleton).
function drawOutline(target, mask, r, g, b, fillIt) {
    selectWindow(mask);
    if (nSlices > 1) return;
    setThreshold(255, 255);
    run("Create Selection");
    resetThreshold();
    if (selectionType() < 0) return;
    selectWindow(target);
    run("Restore Selection");
    setForegroundColor(r, g, b);
    if (fillIt) run("Fill", "slice"); else run("Draw", "slice");
    run("Select None");
    selectWindow(mask);
    run("Select None");
}

function qcBase(cond, rep, name, s, nSeries) {
    base = File.getNameWithoutExtension(name);
    if (endsWith(base, ".ome")) base = substring(base, 0, lengthOf(base) - 4);
    q = cond + "_" + rep + "_" + base;
    q = sanitize(q);
    if (nSeries > 1) q = q + "_S" + (s + 1);
    return q;
}

// Selects cell i (0-based) of the label image "cellLabels" (no ROI Manager: it is unreliable in batch mode).
function cellSelect(i) {
    selectWindow("cellLabels");
    setThreshold(i + 1, i + 1);
    run("Create Selection");
    resetThreshold();
}

// Sum of image title inside cell i.
function roiVal(title, i) {
    cellSelect(i);
    selectWindow(title);
    run("Restore Selection");
    getRawStatistics(n, mean);
    run("Select None");
    return n * mean;
}

// [pixel count, sum] of image title inside cell i.
function roiSum(title, i) {
    cellSelect(i);
    selectWindow(title);
    run("Restore Selection");
    getRawStatistics(n, mean);
    run("Select None");
    return newArray(n, n * mean);
}

// Median and SD of image or stack title outside the (2D) binary mask widened by grow pixels, over all slices,
// and the fraction of the field that is outside. Returns [median, SD, fraction].
function outsideStats(title, mask, grow) {
    selectWindow(mask);
    run("Duplicate...", "title=out_tmp");
    run("Maximum...", "radius=" + maxOf(1, round(grow)));
    run("Invert");
    setThreshold(255, 255);
    run("Create Selection");
    resetThreshold();
    frac = 0; med = 0; sd = 0;
    if (selectionType() >= 0) {
        getRawStatistics(nOut);
        frac = nOut / (getWidth() * getHeight());
        selectWindow(title);
        run("Restore Selection");
        sm = 0; ss = 0; k = 0;
        for (z = 1; z <= nSlices; z++) {
            setSlice(z);
            List.setMeasurements;
            sm = sm + List.getValue("Median"); ss = ss + List.getValue("StdDev"); k++;
        }
        med = sm / k; sd = ss / k;
        setSlice(1);
        run("Select None");
    }
    close("out_tmp");
    return newArray(med, sd, frac);
}

// Histogram of the whole stack in nb bins between mn and mx: [bin starts (nb), counts (nb)].
function stackHistogram(nb, mn, mx) {
    vals = newArray(nb); cnt = newArray(nb);
    w = (mx - mn) / nb; if (w <= 0) w = 1;
    for (b = 0; b < nb; b++) vals[b] = mn + b * w;
    for (z = 1; z <= nSlices; z++) {
        setSlice(z);
        getHistogram(v, c, nb, mn, mx);
        for (b = 0; b < nb; b++) cnt[b] = cnt[b] + c[b];
    }
    setSlice(1);
    return Array.concat(vals, cnt);
}

// Cells (2D) of the open image(s): "nuc01" (nuclei 0/1), "nucmask" (when nuclei are used), "cellmask" and
// "cellLabels" (1..n). Each nucleus seeds a cell; the outline channel (smoothed max projection, threshold method)
// gives its extent (ringUm > 0: a ring of that width around each nucleus instead, for cells without a cell-fill
// marker); touching cells are split halfway between nuclei. Returns the number of cells.
function segmentCells(outlineSrc, useNuc, whole, minCell, minNuc, cellMethod, nucMethod, ringUm, pw) {
    selectWindow(outlineSrc); W = getWidth(); H = getHeight();
    newImage("nuc01", "32-bit black", W, H, 1);
    if (useNuc > 0 && !whole) {
        projectTo("nucch", "nucproj");
        run("Gaussian Blur...", "sigma=" + maxOf(1, 0.5 / pw));
        setAutoThreshold(nucMethod + " dark");
        run("Convert to Mask");
        run("Fill Holes");
        run("Analyze Particles...", "size=" + minNuc + "-Infinity show=Masks clear");
        rename("nucmask"); if (is("Inverting LUT")) run("Invert LUT");
        close("nucproj");
        selectWindow("nucmask"); run("Duplicate...", "title=vor_in");
        run("Voronoi");
        rename("lines");
        setThreshold(1, 255); run("Convert to Mask"); run("Maximum...", "radius=1");
        close("vor_in");
        selectWindow("nucmask"); run("Duplicate...", "title=nucbin"); run("32-bit"); run("Divide...", "value=255");
        imageCalculator("Add", "nuc01", "nucbin"); close("nucbin");
    }
    if (whole) {
        newImage("cellmask", "8-bit white", W, H, 1);
    } else if (ringUm > 0 && isOpen("nucmask")) {
        selectWindow("nucmask"); run("Duplicate...", "title=cellmask");
        run("Maximum...", "radius=" + maxOf(1, round(ringUm / pw)));
        if (isOpen("lines")) { imageCalculator("Subtract", "cellmask", "lines"); close("lines"); }
    } else {
        projectTo(outlineSrc, "cellproj");
        run("Gaussian Blur...", "sigma=" + maxOf(1, 1 / pw));
        setAutoThreshold(cellMethod + " dark");
        run("Convert to Mask");
        run("Fill Holes");
        rename("cellmask");
        if (isOpen("lines")) { imageCalculator("Subtract", "cellmask", "lines"); close("lines"); }
    }
    selectWindow("cellmask");
    if (is("Inverting LUT")) run("Invert LUT");
    run("Analyze Particles...", "size=" + minCell + "-Infinity show=[Count Masks] display clear");
    rename("cellLabels");
    n = nResults;
    run("Clear Results");
    return n;
}

// Plugin version: shown by About and written into every results file.
function pluginVersion() { return "1.0.0"; }
