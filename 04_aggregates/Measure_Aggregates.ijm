// Aggregates workflow: how many cells have aggregates of a protein (e.g. MAVS on mitochondria), and how the protein
// is spread over its organelle, measured per cell in 2D and optionally in 3D.
//
//   1. Choose "Control vs treated" (control folder, then one or more treated folders) or "Absolute" (one file or one
//      folder). A folder can hold the images directly or one subfolder per replicate. Any Bio-Formats format.
//      Choose the protein's origin; the two aggregate differently, so the rule for an aggregated cell differs:
//      ENDOGENOUS (stained): discrete aggregates among normal puncta: steps 4-6 below.
//      EXOGENOUS (transfected / overexpressed): the protein leaves its organelle for a few rods, rings or masses.
//      Cells dimmer than a set multiple of the background noise are untransfected (listed, not measured). Per
//      cell, the protein is outlined with the cell's own threshold (so bright and dim cells are judged alike) and
//      the share of the cell's organelle carrying it is measured; a cell is aggregated when at least a cutoff %
//      of its organelle carries none (live window, one slider, or click aggregated cells). % aggregated is also
//      given per expression bin (tertiles), since overexpressed protein self-aggregates more at high levels.
//   2. Channels: the aggregating protein (e.g. MAVS), its organelle (MitoTracker, TOM20 ...; optional), nuclei
//      (optional) and the channel that outlines the cells (the organelle by default; or "whole field" = one cell).
//   3. Cells: each nucleus seeds one cell; the outline channel (smoothed max projection, Triangle threshold) gives
//      its extent; touching cells are split halfway between nuclei. A cell needs its own nucleus inside.
//   4. Puncta: the protein's max projection, background-subtracted (rolling ball about the radius of the biggest
//      aggregate) and outlined with ONE threshold for all images (Otsu on the control images by default, live
//      window). Touching puncta are split at their necks (watershed): a chain of puncta along a tubule is not one
//      big object, while a round aggregate has no neck and stays whole.
//   5. Aggregates: puncta at least as LARGE and as BRIGHT (x the median punctum of the same cell) as cutoffs YOU
//      set in a second live window: control and treated images, normal puncta yellow, aggregates red. Move the
//      sliders or type values, or click two or three structures you call aggregates (the cutoffs become the
//      smallest and dimmest of them). Size alone is not enough: dense normal puncta merge into objects as big as an
//      aggregate; an aggregate is also denser. Start: 0.5 um2, and just above the brightest control object of that
//      size. One pair of cutoffs for every image; 3D uses the volume of a sphere with that cross-section.
//   6. A cell is AGGREGATED when it has at least 1 aggregate (adjustable): aggregation is close to all-or-none per
//      cell, so the headline is the % of aggregated cells, not an average. The share of control cells called
//      aggregated is reported as the false-positive check: it should be close to 0.
//   7. Readouts per cell: aggregated yes/no, aggregates, puncta, mean punctum area, aggregate area, share of the
//      protein in aggregates and in puncta (background-subtracted sum projection); with an organelle channel, over
//      the cell's voxels (every slice): Pearson protein vs organelle (falls when the protein leaves an even coat for
//      a few foci), Manders M1 (share of the protein on the organelle: stays high when it aggregates there, falls
//      when it is released), and the CV of the protein on the organelle (evenness: rises with aggregation).
//      Optional 3D: aggregates and puncta counted on the full stack (3D Objects Counter).
//   8. Writes aggregates_results.xlsx (Summary relative to control, split by aggregated / non-aggregated cells,
//      Replicates, Images, Cells, Threshold methods, Settings), bar graphs and qc/ images (protein green, organelle
//      red, puncta cyan, aggregates magenta, nuclei grey, cells numbered with "A" when aggregated, legend on top).
//      Statistics use replicate means when every condition has >= 2 replicate subfolders, otherwise image values;
//      never pooled cells (pooled-cell percentages are listed as well). Puncta counts and sizes depend on the pixel
//      size: images with different zoom are flagged.

// ---- settings ----
interactive = true;          // false = use the defaults below without dialogs (testing)
// ------------------

requires("1.54");
setOption("BlackBackground", true);
run("Options...", "iterations=1 count=1 black");

// ---- 1. what to measure ----
modes = newArray("Control vs treated (one or more treated folders, e.g. doses)", "Absolute (no comparison)");
inputs = newArray("A folder", "One file");
analyses = newArray("2D (max projection)", "2D + 3D (full stack)");
origins = newArray("Endogenous protein, stained: aggregates are large, bright puncta among the normal ones",
    "Exogenous, transfected / overexpressed: aggregation is the protein collapsing into one or a few big masses");
mode = modes[0]; input = inputs[0]; analysis = analyses[0]; origin = origins[0];
if (interactive) {
    Dialog.create("Aggregates");
    Dialog.addRadioButtonGroup("Analysis", modes, 2, 1, mode);
    Dialog.addRadioButtonGroup("Dimensions", analyses, 1, 2, analysis);
    Dialog.addRadioButtonGroup("The protein is", origins, 2, 1, origin);
    Dialog.addMessage("Control vs treated: you will pick the control folder, then a treated folder; you can then add\n"
        + "more treated folders. All share the control's threshold, one aggregate cutoff and one graph.\n"
        + "Absolute: measure one file or one folder on its own.\n"
        + "A folder can hold the images directly or one subfolder per replicate. Use raw or deconvolved stacks.");
    Dialog.show();
    mode = Dialog.getRadioButton(); analysis = Dialog.getRadioButton(); origin = Dialog.getRadioButton();
    if (mode == modes[1]) {
        Dialog.create("Aggregates: absolute");
        Dialog.addRadioButtonGroup("Measure", inputs, 1, 2, input);
        Dialog.show();
        input = Dialog.getRadioButton();
    }
}
do3D = false; if (analysis == analyses[1]) do3D = true;
exo = false; if (origin == origins[1]) exo = true;
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
// defaults: a channel named like the dye or shown in the usual colour (protein green, organelle red, nuclei
// blue, as set in the file), otherwise the usual order (C1 nuclei, C2 protein, C3 organelle)
kP = channelLike(chNames, "mavs|gfp|488|fitc|alexa ?488|\\(green", minOf(1, nCh - 1));
kO = channelLike(chNames, "mitotracker|tom ?20|tom ?70|mito|pmp70|sec61|cox|hsp60|\\(red", minOf(2, nCh - 1));
kN = channelLike(chNames, "dapi|hoechst|405|nuc|\\(blue", 0);
if (kO == kP) kO = -1;
NONE_ORG = "None (no Pearson, Manders or evenness)"; NONE_NUC = "None (touching cells are not split)"; WHOLE = "Whole field (one cell per image)";
orgChoices = Array.concat(NONE_ORG, chNames); nucChoices = Array.concat(NONE_NUC, chNames); outlineChoices = Array.concat(chNames, WHOLE);
protCh = chNames[kP];
orgCh = NONE_ORG; if (kO >= 0 && nCh >= 2) orgCh = chNames[kO];
nucCh = NONE_NUC; if (nCh >= 3 && kN != kP && kN != kO) nucCh = chNames[kN];
outlineCh = orgCh; if (orgCh == NONE_ORG) outlineCh = protCh;
methods = getList("threshold.methods");
cellMethod = "Triangle";
bgRadius = 1;          // um, rolling ball for the protein: about the radius of the biggest aggregate
orgRadius = 1;         // um, rolling ball for the organelle
minPunct = 0.03;       // um^2, smaller puncta are noise
minAgg = 1;            // aggregates a cell needs to count as aggregated
minCell = 100;         // um^2
minNuc = 20;           // um^2
nucMethod = "Otsu";    // nuclei threshold (Li catches dim nuclei next to bright ones; Otsu ignores cytoplasmic DAPI haze)
minLevel = 1.5;        // exogenous: a cell's mean protein must reach this many x the background noise (else untransfected)
if (exo) bgRadius = 5; // big masses must survive the background subtraction
excludeEdge = false;
if (interactive) {
    Dialog.create("Aggregates: options");
    if (compare) {
        for (g = 0; g < nCond; g++) {
            nf = countOf(fCond, g);
            label = "Control name"; if (g > 0) label = "Treated " + g + " name";
            Dialog.addString(label, condNames[g], 20);
            Dialog.addToSameRow(); Dialog.addMessage("(" + nf + " files)");
        }
    } else Dialog.addMessage("" + fPath.length + " file(s)");
    Dialog.addChoice("Aggregating protein", chNames, protCh);
    Dialog.addChoice("Its organelle", orgChoices, orgCh);
    Dialog.addChoice("Nuclei", nucChoices, nucCh); Dialog.addToSameRow(); Dialog.addChoice("threshold", newArray("Otsu", "Li", "Huang", "Triangle"), nucMethod);
    Dialog.addChoice("Outline the cells with", outlineChoices, outlineCh);
    Dialog.addChoice("Cell outline threshold", methods, cellMethod);
    Dialog.addNumber("Minimum cell area", minCell, 0, 6, "um2");
    if (!exo) Dialog.addNumber("Aggregates to call a cell aggregated", minAgg, 0, 6, "");
    else Dialog.addNumber("Transfected cells: mean protein at least", minLevel, 1, 6, "x the background noise (dimmer = untransfected)");
    Dialog.addNumber("Background radius", bgRadius, 1, 6, "um (about the radius of the biggest aggregate)");
    Dialog.addNumber("Smallest punctum", minPunct, 2, 6, "um2 (smaller = noise)");
    Dialog.addCheckbox("Exclude cells cut by the image edge", excludeEdge);
    Dialog.addMessage("The aggregate cutoff is set in a live window after the puncta threshold.\n"
        + "MitoTracker depends on membrane potential; TOM20 does not.");
    Dialog.show();
    if (compare) for (g = 0; g < nCond; g++) condNames[g] = Dialog.getString();
    protCh = Dialog.getChoice(); orgCh = Dialog.getChoice(); nucCh = Dialog.getChoice(); nucMethod = Dialog.getChoice(); outlineCh = Dialog.getChoice();
    cellMethod = Dialog.getChoice();
    minCell = Dialog.getNumber();
    if (!exo) minAgg = Dialog.getNumber(); else minLevel = Dialog.getNumber();
    bgRadius = Dialog.getNumber(); minPunct = Dialog.getNumber();
    excludeEdge = Dialog.getCheckbox();
}
for (c = 0; c < nCond; c++) condNames[c] = replace(condNames[c], "[,{}|'\t]", " ");
cP = chIndex(protCh); cO = chIndex(orgCh); cN = chIndex(nucCh);   // 0 = none
whole = false; cL = 0; if (outlineCh == WHOLE) whole = true; else cL = chIndex(outlineCh);
if (cO == cP) exit("The protein and its organelle must be different channels.");
hasOrg = false; if (cO > 0) hasOrg = true;
if (exo && !hasOrg) exit("The exogenous rule asks how much of the organelle still carries the protein: choose its organelle channel.");
qcDir = outDir + "qc" + File.separator;
File.makeDirectory(qcDir);
setBatchMode(true);
skipped = "";

// ---- 3. puncta threshold: every method on the prepared projections of the control images ----
nM = methods.length; NB = 1024;
refT = newArray(); hv = newArray(); hc = newArray(); nRef = 0; nPrev = 0; maxV = 0; orgT = newArray(); sliceNoise = newArray();
for (fi = 0; fi < fPath.length; fi++) {
    if (fCond[fi] != 0) continue;
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { skipped = skipped + seriesProblem(fPath[fi], s, u); continue; }
        chs = newArray(1); chs[0] = cP; names = newArray("prot");
        if (hasOrg) { chs = Array.concat(chs, cO); names = Array.concat(names, "org"); }
        err = loadChannels(fPath[fi], s, chs, names);
        if (err != "") { skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        projectTo("prot", "pp");
        bgp = prepare("pp", bgRadius);
        if (do3D) { selectWindow("prot"); if (nSlices > 1) { b3 = prepare("prot", bgRadius); n3r = noiseRms("prot"); sliceNoise = Array.concat(sliceNoise, n3r); } }
        if (hasOrg) {
            bgo = prepare("org", orgRadius);
            selectWindow("org"); setAutoThreshold("Otsu dark stack"); getThreshold(lo, hi); resetThreshold();
            orgT = Array.concat(orgT, lo);
            close("org");
        }
        close("prot");
        selectWindow("pp");
        for (m = 0; m < nM; m++) {
            setAutoThreshold(methods[m] + " dark");
            getThreshold(lo, hi);
            refT = Array.concat(refT, lo);
        }
        resetThreshold();
        getHistogram(values, counts, NB);
        hv = Array.concat(hv, values); hc = Array.concat(hc, counts);
        maxV = maxOf(maxV, values[NB - 1]);
        nRef++;
        if (nPrev < 6) { nPrev++; rename("ref" + nPrev); } else close("pp");
    }
}
if (nRef == 0) exit("None of the " + condNames[0] + " images could be read.\n" + skipped);
Torg = NaN; if (orgT.length > 0) Torg = medianOf(orgT);
noise3 = 0; if (sliceNoise.length > 0) noise3 = medianOf(sliceNoise);
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
    labels[k] = methods[m] + ":  " + d2s(mT[m], 1) + "   (" + d2s(mPct[m], 1) + "% of the image outlined)";
    if (k == 0) labels[k] = labels[k] + "  default";
}
T = ordT[0]; method = methods[order[0]];
if (nPrev > 1) run("Images to Stack", "method=[Copy (center)] name=preview title=ref use");
else { selectWindow("ref1"); rename("preview"); }
if (interactive) {
    selectWindow("preview");
    run("Grays");
    run("Enhance Contrast", "saturated=0.35");
    setBatchMode("show");
    msg = "Every threshold method was tried on the protein of " + nRef + " " + condNames[0] + " image(s) (prepared max projections).\n"
        + "Default: Otsu; the other methods are listed from low to high.\n"
        + "Yellow outlines = what counts as puncta: every punctum should be outlined, the haze between them not.\n"
        + "Type a value, move the slider or pick a method; scroll the image to check the other images.\n"
        + "This one value is applied to every image. The aggregate size is set next.";
    r = thresholdDialog("Aggregates: puncta threshold", msg, labels, ordT, maxV);
    if (r == "cancel") exit;
    if (startsWith(r, "ERR")) exit("Threshold window failed: " + r);
    f = split(r, "\t"); T = parseFloat(f[0]); method = methods[order[parseInt(f[1])]];
    if (f[2] == "1") method = method + " (edited)";
}
close("preview");
T3 = maxOf(T, 5 * noise3);
print("Puncta threshold: " + T + " (" + method + ", from " + nRef + " images)");
methodRows = "Method\tThreshold (prepared protein)\tOutlined area (%)\n";
for (k = 0; k < nM; k++) { m = order[k]; methodRows = methodRows + methods[m] + "\t" + d2s(mT[m], 3) + "\t" + d2s(mPct[m], 3) + "\n"; }

// ---- 4. aggregates: size AND brightness. Puncta of up to 6 images (control and treated), each with its area (um2)
//      and its brightness relative to the median punctum of its image (normalises staining between images) ----
pick = newArray(); ctrlA = newArray(); ctrlB = newArray(); allObj = "";
pvS = newArray(); pvL = newArray(); pvC = newArray(); pvCount = newArray();   // exogenous: share, level, condition per cell
for (g = 0; g < nCond; g++) { nTake = 0; for (fi = 0; fi < fPath.length; fi++) if (fCond[fi] == g && nTake < 3) { pick = Array.concat(pick, fi); nTake++; } }
nSz = 0;
for (q = 0; q < pick.length && nSz < 6; q++) {
    fi = pick[q];
    use = usableSeries(fPath[fi]);
    if (use[0] < 0) continue;
    chs = newArray(1); chs[0] = cP; names = newArray("prot");
    if (hasOrg) { chs = Array.concat(chs, cO); names = Array.concat(names, "org"); }
    if (cN > 0) { chs = Array.concat(chs, cN); names = Array.concat(names, "nucch"); }
    if (!whole && cL != cP && cL != cO && cL != cN) { chs = Array.concat(chs, cL); names = Array.concat(names, "cellch"); }
    err = loadChannels(fPath[fi], use[0], chs, names);
    if (err != "") continue;
    outlineSrc = "prot"; if (cL == cO) outlineSrc = "org"; if (cL == cN && cN > 0) outlineSrc = "nucch"; if (isOpen("cellch")) outlineSrc = "cellch";
    selectWindow("prot"); getPixelSize(unit, pw, ph);
    nCells = segmentCells(outlineSrc, cN, whole, minCell, minNuc, cellMethod, nucMethod, 0, pw);
    // same background subtraction as the measurement, so brightness ratios match what is measured
    noise = NaN;
    if (!whole) { bgN = outsideStats("prot", "cellmask", 2 / pw); noise = bgN[1]; selectWindow("prot"); run("Subtract...", "value=" + bgN[0] + " stack"); }
    projectTo("prot", "szraw");
    selectWindow("szraw"); run("Duplicate...", "title=pp");
    bgp = prepare("pp", bgRadius);
    selectWindow("pp");
    setThreshold(T, 1e30); run("Convert to Mask");
    if (exo) {
        selectWindow("prot"); nzp = nSlices; sumOf("prot", "szsum");
        orgMask2D("org", orgRadius, Torg, "szorg");
        sh = organelleCoverage("szsum", "szorg", nCells, "szlab" + (nSz + 1));
        lv = cellLevels("szsum", nCells, nzp, noise);
        for (ci = 0; ci < nCells; ci++) { x = sh[ci]; y = lv[ci]; z = fCond[fi]; pvS = Array.concat(pvS, x); pvL = Array.concat(pvL, y); pvC = Array.concat(pvC, z); }
        pvCount = Array.concat(pvCount, nCells);
        nSz++;
        selectWindow("szraw"); rename("szimg" + nSz); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        list = getList("image.titles");
        for (j = 0; j < list.length; j++) if (!startsWith(list[j], "szimg") && !startsWith(list[j], "szlab")) close(list[j]);
        continue;
    }
    run("Watershed");      // touching puncta along a tubule are split at their necks; a round aggregate stays whole
    run("Set Measurements...", "area mean centroid redirect=szraw decimal=4");
    run("Analyze Particles...", "size=" + minPunct + "-Infinity show=[Count Masks] display clear");
    rename("szlab" + (nSz + 1));
    nO = nResults; mm = newArray(nO); xs = newArray(nO); ys = newArray(nO);
    for (r = 0; r < nO; r++) { mm[r] = getResult("Mean", r); xs[r] = getResult("X", r) / pw; ys[r] = getResult("Y", r) / pw; }
    rat = perCellRatio(mm, xs, ys);
    o = "";
    for (r = 0; r < nO; r++) {
        ar = getResult("Area", r); br = rat[r];
        o = o + d2s(ar, 4) + ":" + d2s(br, 3) + ",";
        if (fCond[fi] == 0) { ctrlA = Array.concat(ctrlA, ar); ctrlB = Array.concat(ctrlB, br); }
    }
    run("Clear Results"); run("Set Measurements...", "area mean redirect=None decimal=4");
    allObj = allObj + o + ";";
    nSz++;
    selectWindow("szraw"); rename("szimg" + nSz); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
    close("pp");
    list = getList("image.titles");
    for (j = 0; j < list.length; j++) if (!startsWith(list[j], "szimg") && !startsWith(list[j], "szlab")) close(list[j]);
}
// start: 0.5 um2 (clearly larger than a diffraction-limited punctum) and just above the brightest control object of
// that size, so the reference controls start with no aggregates
cut = 0.5; bright = 1.5;
for (k = 0; k < ctrlA.length; k++) if (ctrlA[k] >= cut) bright = maxOf(bright, ctrlB[k] + 0.05);
if (exo) {
    // exogenous: one value per cell = % of its organelle left without the protein (untransfected cells 0);
    // start just above the highest transfected control cell (at least 50%)
    bright = 1; cut = 50; allObj = ""; k = 0;
    for (j = 0; j < pvCount.length; j++) {
        o = "";
        for (ci = 0; ci < pvCount[j]; ci++) {
            ok = false; if (isNaN(pvL[k])) ok = true; else if (pvL[k] >= minLevel) ok = true;
            v = 0; if (ok && !isNaN(pvS[k])) v = 100 * (1 - pvS[k]);
            if (ok && pvC[k] == 0) cut = maxOf(cut, v + 2);
            o = o + d2s(v, 2) + ":1,";
            k++;
        }
        allObj = allObj + o + ";";
    }
    cut = minOf(95, cut);
}
cutStart = cut; brightStart = bright;
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }
if (interactive && nSz > 0) {
    if (nSz > 1) { run("Images to Stack", "method=[Copy (center)] name=sizeprev title=szimg use"); run("Images to Stack", "method=[Copy (center)] name=sizelab title=szlab use"); }
    else { selectWindow("szimg1"); rename("sizeprev"); selectWindow("szlab1"); rename("sizelab"); }
    selectWindow("sizeprev");
    setBatchMode("show");
    if (exo) msg = "Control and treated images (scroll through them). Outlined: each cell's protein (its own threshold, so bright\n"
        + "and dim cells are judged alike). Spread over its organelle, the protein covers most of it; aggregated, it has left\n"
        + "most of the organelle for a few rods, rings or masses. A cell is AGGREGATED (red) when at least this share of its\n"
        + "organelle carries no protein; yellow = not aggregated. Move the slider or type a value, or click a cell you call\n"
        + "aggregated: the cutoff drops to 80% of its value. Untransfected cells (below the level in the options) stay yellow.\n"
        + "Start: " + d2s(cutStart, 1) + "%, just above the highest control cell. Applied to every image.";
    else msg = "Puncta of control and treated images (scroll through them). Yellow = normal puncta, red = aggregates:\n"
        + "at least the size AND at least the brightness (x the median punctum of the same cell). Dense normal\n"
        + "puncta can merge into objects as big as an aggregate; an aggregate is also denser. Move the sliders or\n"
        + "type values; or click one or more structures you call aggregates: both cutoffs drop to 80% of\n"
        + "the smallest and dimmest of them, so similar aggregates are caught too.\nStart: " + d2s(cutStart, 2) + " um2 and just above the brightest control object of that size.\n"
        + "Brightness 1 = size only. These cutoffs are applied to every image.";
    if (exo) r = sizeDialog("Aggregates: organelle left without the protein", msg, allObj, cut, 100, 1, 1, "Organelle without protein (%)", "");
    else r = sizeDialog("Aggregates: aggregate size and brightness", msg, allObj, cut, maxOf(5, 4 * cut), bright, maxOf(5, 2 * bright), "Aggregate size (um2)", "Brightness (x median punctum)");
    if (r == "cancel") exit;
    if (startsWith(r, "ERR")) exit("Aggregate window failed: " + r);
    f = split(r, "\t"); cut = parseFloat(f[0]); bright = parseFloat(f[1]);
    close("sizeprev"); close("sizelab");
}
close("szimg*"); close("szlab*");
volCut = 4 / 3 * pow(cut, 1.5) / sqrt(PI);   // volume of a sphere whose cross-section is cut
if (exo) print("Aggregated cells: >= " + d2s(cut, 1) + "% of the organelle without protein; transfected: mean >= " + minLevel + " x background noise");
else print("Aggregates: >= " + cut + " um2 (3D: " + d2s(volCut, 4) + " um3) and >= " + bright + " x the median punctum brightness");

// ---- 5. measure every cell of every image ----
iCond = newArray(); iRep = newArray(); iFile = newArray(); iSer = newArray(); iQc = newArray(); iW = newArray(); iPx = newArray(); iNz = newArray();
cImg = newArray(); cLabel = newArray(); cEdge = newArray(); cArea = newArray(); cX = newArray(); cY = newArray();
cAgg = newArray(); cPun = newArray(); cMeanA = newArray(); cAggA = newArray(); cShA = newArray(); cShP = newArray();
cPear = newArray(); cM1 = newArray(); cCV = newArray(); cAgg3 = newArray(); cObj3 = newArray(); cVol3 = newArray();
cLev = newArray(); cLg = newArray();   // exogenous: protein level, share of the organelle carrying the protein
noBgList = "";
for (fi = 0; fi < fPath.length; fi++) {
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (fCond[fi] != 0) skipped = skipped + seriesProblem(fPath[fi], s, u); continue; }
        chs = newArray(1); chs[0] = cP; names = newArray("prot");
        if (hasOrg) { chs = Array.concat(chs, cO); names = Array.concat(names, "org"); }
        if (cN > 0) { chs = Array.concat(chs, cN); names = Array.concat(names, "nucch"); }
        if (!whole && cL != cP && cL != cO && cL != cN) { chs = Array.concat(chs, cL); names = Array.concat(names, "cellch"); }
        err = loadChannels(fPath[fi], s, chs, names);
        if (err != "") { if (fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        outlineSrc = "prot"; if (cL == cO) outlineSrc = "org"; if (cL == cN && cN > 0) outlineSrc = "nucch"; if (isOpen("cellch")) outlineSrc = "cellch";
        name = File.getName(fPath[fi]);
        cname = condNames[fCond[fi]];
        qb = qcBase(cname, fRep[fi], name, s, use.length);
        selectWindow("prot");
        getVoxelSize(pw, ph, pd, unit);
        nz = nSlices;
        W = getWidth(); H = getHeight();
        nCells = segmentCells(outlineSrc, cN, whole, minCell, minNuc, cellMethod, nucMethod, 0, pw);
        // protein background: median outside the cells (none in whole-field mode)
        pBg = 0; oBg = 0; noise = NaN;
        if (!whole) {
            bgN = outsideStats("prot", "cellmask", 2 / pw); pBg = bgN[0]; noise = bgN[1];
            if (bgN[2] < 0.02) noBgList = noBgList + name + "\n";
            if (hasOrg) { oN = outsideStats("org", "cellmask", 2 / pw); oBg = oN[0]; }
        }
        selectWindow("prot"); run("Duplicate...", "title=praw duplicate"); run("Subtract...", "value=" + pBg + " stack");
        sumOf("praw", "sP");
        // 2D puncta and aggregates
        projectTo("prot", "pp");
        bgp = prepare("pp", bgRadius);
        selectWindow("pp"); setThreshold(T, 1e30); run("Convert to Mask");
        run("Watershed");      // touching puncta along a tubule are split at their necks; a round aggregate stays whole
        run("Analyze Particles...", "size=" + minPunct + "-Infinity show=Masks clear");
        rename("pm"); if (is("Inverting LUT")) run("Invert LUT");
        close("pp");
        // endogenous: aggregates = puncta >= cut um2 AND >= bright x the median punctum of the cell
        // (exogenous: filled in after the organelle, below)
        newImage("am", "8-bit black", W, H, 1);
        setVoxelSize(pw, ph, pd, unit);
        covs = newArray(nCells); lvs = newArray(nCells);
        if (!exo) {
        projectTo("praw", "pmaxr");
        selectWindow("pm");
        run("Set Measurements...", "area mean centroid redirect=pmaxr decimal=4");
        run("Analyze Particles...", "size=" + minPunct + "-Infinity show=[Count Masks] display clear");
        rename("plab");
        nObj = nResults; oa = newArray(nObj); om = newArray(nObj); xs = newArray(nObj); ys = newArray(nObj);
        for (r = 0; r < nObj; r++) { oa[r] = getResult("Area", r); om[r] = getResult("Mean", r); xs[r] = getResult("X", r) / pw; ys[r] = getResult("Y", r) / pw; }
        run("Clear Results"); run("Set Measurements...", "area mean redirect=None decimal=4");
        rat = perCellRatio(om, xs, ys);
        for (r = 0; r < nObj; r++) if (oa[r] >= cut && rat[r] >= bright) {
            selectWindow("plab"); setThreshold(r + 1, r + 1); run("Create Selection"); resetThreshold();
            selectWindow("am"); run("Restore Selection"); run("Set...", "value=255"); run("Select None");
        }
        close("plab"); close("pmaxr");
        }
        // 3D puncta and aggregates (3D Objects Counter on the prepared stack)
        oX = newArray(); oY = newArray(); oV = newArray(); oM = newArray(); rat3 = newArray();
        if (do3D && nz > 1) {
            // the 3D Objects Counter only measures intensities on 8- or 16-bit stacks
            selectWindow("praw"); run("Duplicate...", "title=praw16 duplicate"); scl = call("ij.process.ImageConverter.getDoScaling"); setOption("ScaleConversions", false); run("16-bit"); setOption("ScaleConversions", scl == "true");
            selectWindow("prot"); run("Duplicate...", "title=p3 duplicate");
            b3 = prepare("p3", bgRadius);
            selectWindow("p3"); setThreshold(T3, 1e30); run("Convert to Mask", "background=Dark black");
            minVox = maxOf(1, round(minPunct / (pw * ph)));
            run("Clear Results");
            run("3D OC Options", "volume mean_gray_value centroid nb_of_obj._voxels dots_size=5 font_size=10 redirect_to=praw16");
            run("3D Objects Counter", "threshold=128 slice=1 min.=" + minVox + " max=999999999 statistics");
            run("3D OC Options", "volume mean_gray_value centroid nb_of_obj._voxels dots_size=5 font_size=10 redirect_to=none");
            head = split(String.getResultsHeadings, "\t"); volCol = "";
            for (h = 0; h < head.length; h++) if (startsWith(head[h], "Volume")) volCol = head[h];
            oM = newArray();
            for (r = 0; r < nResults; r++) { x3 = getResult("X", r); y3 = getResult("Y", r); v3 = getResult(volCol, r); m3 = getResult("Mean", r); oX = Array.concat(oX, x3); oY = Array.concat(oY, y3); oV = Array.concat(oV, v3); oM = Array.concat(oM, m3); }
            run("Clear Results");
            rat3 = perCellRatio(oM, oX, oY);
            close("p3"); close("praw16");
        }
        // organelle: Pearson, Manders M1 and evenness (CV) over the cell's voxels (cell in 3D: outline channel, Otsu)
        if (hasOrg) {
            selectWindow("org"); run("Duplicate...", "title=oraw duplicate"); run("Subtract...", "value=" + oBg + " stack");
            bgo = prepare("org", orgRadius);
            selectWindow("org"); setThreshold(Torg, 1e30); run("Convert to Mask", "background=Dark black");
            run("Divide...", "value=255 stack"); run("32-bit"); rename("m01");
            if (whole) { selectWindow("praw"); run("Duplicate...", "title=c301 duplicate"); run("Multiply...", "value=0 stack"); run("Add...", "value=1 stack"); }
            else {
                src3 = outlineSrc; if (outlineSrc == "org") src3 = "oraw";   // "org" is the organelle mask by now
                selectWindow(src3);
                run("Duplicate...", "title=c301 duplicate");
                sg = maxOf(1, 1 / pw);
                if (nSlices > 1) run("Gaussian Blur 3D...", "x=" + sg + " y=" + sg + " z=1"); else run("Gaussian Blur...", "sigma=" + sg);
                setAutoThreshold("Otsu dark stack"); run("Convert to Mask", "background=Dark black");
                run("Divide...", "value=255 stack"); run("32-bit"); rename("c301");
            }
            imageCalculator("Multiply create 32-bit stack", "praw", "c301"); rename("pv");
            imageCalculator("Multiply create 32-bit stack", "oraw", "c301"); rename("ov");
            sumOf("c301", "sV"); sumOf("pv", "sPv"); sumOf("ov", "sOv");
            sumProduct("pv", "pv", "sPP"); sumProduct("ov", "ov", "sOO"); sumProduct("pv", "ov", "sPO");
            sumProduct("pv", "m01", "sPM");
            imageCalculator("Multiply create 32-bit stack", "m01", "c301"); rename("mv"); sumOf("mv", "sMV");
            imageCalculator("Multiply create 32-bit stack", "pv", "pv"); rename("pp2"); sumProduct("pp2", "m01", "sPPM"); close("pp2");
            close("pv"); close("ov"); close("mv"); close("c301");
        }
        // exogenous: share of each cell's organelle carrying the protein (protein thresholded per cell); a transfected
        // cell is aggregated when at least cut % of its organelle carries none; its protein is then the aggregate
        if (exo) {
            orgMask2D("m01", 0, 0, "org2d");
            covs = organelleCoverage("sP", "org2d", nCells, "covlab");
            lvs = cellLevels("sP", nCells, nz, noise);
            for (ci = 0; ci < nCells; ci++) {
                tx = true; if (!isNaN(lvs[ci]) && lvs[ci] < minLevel) tx = false;
                if (tx && 100 * (1 - covs[ci]) >= cut) {
                    selectWindow("covlab"); setThreshold(ci + 1, ci + 1); run("Create Selection"); resetThreshold();
                    if (selectionType() >= 0) { selectWindow("am"); run("Restore Selection"); run("Set...", "value=255"); run("Select None"); }
                    selectWindow("covlab"); run("Select None");
                }
            }
            close("covlab"); close("org2d");
        }
        selectWindow("pm"); run("Duplicate...", "title=pm01"); run("32-bit"); run("Divide...", "value=255");
        selectWindow("am"); run("Duplicate...", "title=am01"); run("32-bit"); run("Divide...", "value=255");
        imageCalculator("Multiply create 32-bit", "sP", "pm01"); rename("sPpun");
        imageCalculator("Multiply create 32-bit", "sP", "am01"); rename("sPagg");
        // QC base: protein green, organelle red (max projections); puncta cyan, aggregates magenta, nuclei grey
        projectTo("praw", "pmax");
        selectWindow("pmax"); run("Duplicate...", "title=qg"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        if (hasOrg) {
            projectTo("oraw", "omax"); selectWindow("omax"); run("Duplicate...", "title=qt"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
            run("Merge Channels...", "c1=qt c2=qg create"); run("RGB Color"); rename("qc"); close("Composite");
        } else { selectWindow("qg"); run("RGB Color"); rename("qc"); }
        drawOutline("qc", "pm", 0, 220, 255, false);
        drawOutline("qc", "am", 255, 0, 255, true);
        if (isOpen("nucmask")) drawOutline("qc", "nucmask", 150, 150, 150, false);
        for (ci = 0; ci < nCells; ci++) {
            cellSelect(ci);
            getSelectionBounds(bx, by, bw, bh);
            run("Select None");
            edge = false; if (!whole && (bx <= 0 || by <= 0 || bx + bw >= W || by + bh >= H)) edge = true;
            A = roiSum("nuc01", ci);
            nPix = A[0]; nucPix = A[1];
            if (cN > 0 && !whole && nucPix * pw * ph < minNuc) continue;   // no nucleus of its own: not a cell
            // puncta and aggregates of this cell (2D)
            cellSelect(ci); selectWindow("pm"); run("Restore Selection");
            run("Analyze Particles...", "size=" + minPunct + "-Infinity display clear");
            nP = nResults; sumA = 0;
            for (r = 0; r < nP; r++) { ar = getResult("Area", r); sumA += ar; }
            run("Clear Results"); selectWindow("pm"); run("Select None");
            cellSelect(ci); selectWindow("am"); run("Restore Selection");
            run("Analyze Particles...", "size=0-Infinity display clear");
            nA = nResults; aggA = 0; for (r = 0; r < nA; r++) { ar = getResult("Area", r); aggA += ar; }
            if (exo) { nA = 0; if (aggA > 0) nA = 1; }   // exogenous: the cell's protein as a whole is the aggregate
            run("Clear Results"); selectWindow("am"); run("Select None");
            meanA = NaN; if (nP > 0) meanA = sumA / nP;
            Ptot = roiVal("sP", ci); shP = roiVal("sPpun", ci) / Ptot; shA = roiVal("sPagg", ci) / Ptot;
            // 3D objects whose centre lies in this cell
            n3 = NaN; a3 = NaN; mv3 = NaN;
            if (oX.length > 0) {
                selectWindow("cellLabels"); n3 = 0; a3 = 0; sv = 0;
                for (o = 0; o < oX.length; o++) if (getPixel(floor(oX[o]), floor(oY[o])) == ci + 1) { n3++; sv += oV[o]; if (oV[o] >= volCut && rat3[o] >= bright) a3++; }
                if (n3 > 0) mv3 = sv / n3;
                if (exo) a3 = NaN;   // the exogenous call is made on the cell's organelle coverage (2D)
            }
            lev = lvs[ci]; lg = covs[ci]; if (!exo) { lev = NaN; lg = NaN; }
            pear = NaN; m1 = NaN; cv = NaN;
            if (hasOrg) {
                nv = roiVal("sV", ci); Ps = roiVal("sPv", ci); Os = roiVal("sOv", ci); PP = roiVal("sPP", ci); OO = roiVal("sOO", ci); PO = roiVal("sPO", ci);
                pear = (PO - Ps * Os / nv) / sqrt((PP - Ps * Ps / nv) * (OO - Os * Os / nv));
                m1 = roiVal("sPM", ci) / Ps;
                nmv = roiVal("sMV", ci); mmean = roiVal("sPM", ci) / nmv; mvar = roiVal("sPPM", ci) / nmv - mmean * mmean;
                cv = sqrt(maxOf(0, mvar)) / mmean;
                if (nmv == 0) cv = NaN;
            }
            label = ci + 1;
            // (macro language: array functions need plain variables, not expressions, as arguments)
            imgNo = iCond.length; area = nPix * pw * ph;
            cImg = Array.concat(cImg, imgNo); cLabel = Array.concat(cLabel, label); cEdge = Array.concat(cEdge, edge); cArea = Array.concat(cArea, area);
            cAgg = Array.concat(cAgg, nA); cPun = Array.concat(cPun, nP); cMeanA = Array.concat(cMeanA, meanA); cAggA = Array.concat(cAggA, aggA);
            cShA = Array.concat(cShA, shA); cShP = Array.concat(cShP, shP); cPear = Array.concat(cPear, pear); cM1 = Array.concat(cM1, m1); cCV = Array.concat(cCV, cv);
            cAgg3 = Array.concat(cAgg3, a3); cObj3 = Array.concat(cObj3, n3); cVol3 = Array.concat(cVol3, mv3);
            cLev = Array.concat(cLev, lev); cLg = Array.concat(cLg, lg);
            // QC: outline, number, A when aggregated
            cellSelect(ci); selectWindow("qc"); run("Restore Selection");
            Roi.getBounds(lx, ly, lw, lh);
            setForegroundColor(255, 255, 255); run("Draw", "slice");
            run("Select None");
            setFont("SansSerif", maxOf(14, round(W / 45)), "bold antialiased");
            tag = "" + label; if (nA >= minAgg) tag = tag + " A";
            if (exo && !isNaN(lev) && lev < minLevel) tag = "" + label + " u";
            setColor(255, 255, 255); drawString(tag, lx + lw / 2, ly + lh / 2);
            mx2 = lx + lw / 2; my2 = ly + lh / 2;
            cX = Array.concat(cX, mx2); cY = Array.concat(cY, my2);
        }
        iCond = Array.concat(iCond, fCond[fi]); iRep = Array.concat(iRep, fRep[fi]); iFile = Array.concat(iFile, name); iSer = Array.concat(iSer, s + 1);
        qcFile = qcDir + qb + "_qc.png";
        iQc = Array.concat(iQc, qcFile); iW = Array.concat(iW, W); iPx = Array.concat(iPx, pw); iNz = Array.concat(iNz, nz);
        print(cname + " / " + name + ": " + nCells + " cell outline(s)");
        selectWindow("qc");
        legend = "green: " + protCh; if (hasOrg) legend = legend + "   red: " + orgCh;
        legend = legend + "   cyan: puncta   magenta: aggregates   grey: nuclei   white: cells (A = aggregated";
        if (exo) legend = legend + ", u = untransfected"; legend = legend + ")";
        setFont("SansSerif", maxOf(12, round(W / 70)), "antialiased"); setColor(255, 255, 255); drawString(legend, 5, maxOf(14, round(W / 70)) + 4);
        saveAs("PNG", qcFile);
        close("*");
    }
}
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }
if (iCond.length == 0) exit("No image could be measured.\n" + skipped);
if (cImg.length == 0) exit("No cells were found. Check the channels and the qc/ images.\n" + skipped);

// ---- 6. per cell: status and aggregated yes/no; per image: % aggregated cells and means ----
cStatus = newArray(cImg.length); cIsAgg = newArray(cImg.length); cIsAgg3 = newArray(cImg.length);
for (k = 0; k < cImg.length; k++) {
    cStatus[k] = "measured";
    if (exo && !isNaN(cLev[k]) && cLev[k] < minLevel) cStatus[k] = "too dim (untransfected)";
    if (excludeEdge && cEdge[k]) cStatus[k] = "cut by the image edge";
    cIsAgg[k] = 0; if (cAgg[k] >= minAgg) cIsAgg[k] = 1;
    cIsAgg3[k] = NaN; if (!isNaN(cAgg3[k])) { cIsAgg3[k] = 0; if (cAgg3[k] >= minAgg) cIsAgg3[k] = 1; }
}
keys = newArray("pct", "agg", "pun", "meanA", "shA", "shP", "pear", "m1", "cv", "pct3", "agg3", "obj3", "vol3", "lg", "lev");
rNames = newArray("Aggregated cells (%)", "Aggregates per cell", "Puncta per cell", "Mean punctum area (um2)", "Share of protein in aggregates",
    "Share of protein in puncta", "Pearson (protein vs organelle)", "Manders M1 (protein on organelle)", "Evenness on organelle (CV)",
    "Aggregated cells 3D (%)", "Aggregates per cell 3D", "Puncta per cell 3D", "Mean punctum volume 3D (um3)",
    "Organelle carrying the protein (share)", "Protein level (x background noise)");
nK = keys.length; nI = iCond.length; nC = cImg.length;
// every readout of every cell in one table: cVals[q * nC + k] (macro functions cannot see these arrays)
cVals = newArray(nK * nC);
for (k = 0; k < nC; k++) {
    cVals[k] = 100 * cIsAgg[k]; cVals[nC + k] = cAgg[k]; cVals[2 * nC + k] = cPun[k]; cVals[3 * nC + k] = cMeanA[k];
    cVals[4 * nC + k] = cShA[k]; cVals[5 * nC + k] = cShP[k]; cVals[6 * nC + k] = cPear[k]; cVals[7 * nC + k] = cM1[k];
    cVals[8 * nC + k] = cCV[k]; cVals[9 * nC + k] = 100 * cIsAgg3[k]; cVals[10 * nC + k] = cAgg3[k]; cVals[11 * nC + k] = cObj3[k]; cVals[12 * nC + k] = cVol3[k];
    cVals[13 * nC + k] = cLg[k]; cVals[14 * nC + k] = cLev[k];
}
iv = newArray(nK * nI); iCells = newArray(nI); iOut = newArray(nI);
for (i = 0; i < nI; i++) {
    for (q = 0; q < nK; q++) {
        sum = 0; n = 0;
        for (k = 0; k < cImg.length; k++) {
            if (cImg[k] != i) continue;
            if (cStatus[k] != "measured") { if (q == 0) iOut[i] = iOut[i] + 1; continue; }
            if (q == 0) iCells[i] = iCells[i] + 1;
            x = cVals[q * nC + k];
            if (!isNaN(x)) { sum += x; n++; }
        }
        iv[q * nI + i] = NaN; if (n > 0) iv[q * nI + i] = sum / n;
    }
    print(condNames[iCond[i]] + " / " + iFile[i] + ": " + iCells[i] + " cells, " + d2s(iv[i], 0) + "% aggregated, " + d2s(iv[nI + i], 2) + " aggregates per cell, Pearson " + d2s(iv[6 * nI + i], 3));
}

// ---- 7. tables ----
useReps = compare;
for (c = 0; c < nCond; c++) if (repCount(iRep, iCond, c) < 2) useReps = false;
unitName = "images"; if (useReps) unitName = "replicates";
graphed = newArray(0, 1, 4, 6, 7, 8); if (exo) graphed = newArray(0, 13, 6, 7, 8, 14);
if (do3D) graphed = Array.concat(graphed, 9);
summary = "Readout\tCondition\tMean\tSD\tn (" + unitName + ")";
if (compare) summary = summary + "\tRelative to " + condNames[0] + "\tChange vs " + condNames[0] + " (%)";
summary = summary + "\n";
graphs = newArray();
for (q = 0; q < nK; q++) {
    if (!readoutShown(q, hasOrg, do3D, exo)) continue;
    v = Array.slice(iv, q * nI, (q + 1) * nI);
    gMean = newArray(nCond); gSd = newArray(nCond); px = newArray(); py = newArray();
    for (c = 0; c < nCond; c++) {
        pts = unitValues(v, iCond, iRep, c, useReps);
        gm = NaN; gs = NaN;
        if (pts.length > 0) Array.getStatistics(pts, mn, mx, gm, gs);
        if (pts.length < 2) gs = NaN;
        gMean[c] = gm; gSd[c] = gs;
        for (i = 0; i < pts.length; i++) { px = Array.concat(px, c + 0.25 * (i - (pts.length - 1) / 2) / maxOf(1, pts.length - 1)); py = Array.concat(py, pts[i]); }
        summary = summary + rNames[q] + "\t" + condNames[c] + "\t" + d2s(gm, 4) + "\t" + d2s(gs, 4) + "\t" + pts.length;
        if (compare && gMean[0] != 0) summary = summary + "\t" + d2s(gm / gMean[0], 4) + "\t" + d2s(100 * (gm / gMean[0] - 1), 2);
        else if (compare) summary = summary + "\tn/a\tn/a";
        summary = summary + "\n";
    }
    isGraphed = false; for (i = 0; i < graphed.length; i++) if (graphed[i] == q) isGraphed = true;
    if (compare && isGraphed) {
        gFile = outDir + "bar_" + q + ".png";
        gFile = barGraph(rNames[q], condNames, gMean, gSd, px, py, unitName, gFile);
        graphs = Array.concat(graphs, gFile);
    }
}
// pooled cells: % aggregated, and the organelle readouts split by state
summary = summary + "\nPooled cells\tCondition\tAggregated cells\tCells\tAggregated cells (%)\n";
fp = NaN;
for (c = 0; c < nCond; c++) {
    na = 0; nc = 0;
    for (k = 0; k < cImg.length; k++) if (cStatus[k] == "measured") { if (iCond[cImg[k]] == c) { nc++; na += cIsAgg[k]; } }
    pc = NaN; if (nc > 0) pc = 100 * na / nc;
    if (c == 0) fp = pc;
    summary = summary + "Aggregated cells, pooled\t" + condNames[c] + "\t" + na + "\t" + nc + "\t" + d2s(pc, 2) + "\n";
}
// exogenous: overexpressed protein self-aggregates more the more of it a cell has, so % aggregated is also given
// within three expression bins (tertiles of the protein level of all measured cells, the same edges for every condition)
if (exo) {
    lvAll = newArray();
    for (k = 0; k < nC; k++) if (cStatus[k] == "measured" && !isNaN(cLev[k])) { x = cLev[k]; lvAll = Array.concat(lvAll, x); }
    if (lvAll.length >= 3) {
        Array.sort(lvAll); e1 = lvAll[floor(lvAll.length / 3)]; e2 = lvAll[floor(2 * lvAll.length / 3)];
        binNames = newArray("low", "mid", "high");
        summary = summary + "\nBy expression (pooled cells)\tCondition\tProtein level (x background noise)\tAggregated cells\tCells\tAggregated cells (%)\n";
        for (c = 0; c < nCond; c++) for (b = 0; b < 3; b++) {
            na = 0; nc = 0;
            for (k = 0; k < nC; k++) {
                if (cStatus[k] != "measured" || isNaN(cLev[k]) || iCond[cImg[k]] != c) continue;
                bk = 0; if (cLev[k] >= e1) bk = 1; if (cLev[k] >= e2) bk = 2;
                if (bk == b) { nc++; na += cIsAgg[k]; }
            }
            rng = "< " + d2s(e1, 1); if (b == 1) rng = d2s(e1, 1) + " to " + d2s(e2, 1); if (b == 2) rng = ">= " + d2s(e2, 1);
            pc = NaN; if (nc > 0) pc = 100 * na / nc;
            summary = summary + "Aggregated cells, " + binNames[b] + " expression\t" + condNames[c] + "\t" + rng + "\t" + na + "\t" + nc + "\t" + d2s(pc, 2) + "\n";
        }
    }
}
if (hasOrg) {
    summary = summary + "\nBy cell state (pooled cells)\tCondition\tState\tMean\tSD\tn (cells)\n";
    for (q = 6; q <= 8; q++) for (c = 0; c < nCond; c++) for (st = 1; st >= 0; st--) {
        vals = newArray();
        for (k = 0; k < cImg.length; k++) if (cStatus[k] == "measured" && cIsAgg[k] == st) { if (iCond[cImg[k]] == c) { x = cVals[q * nC + k]; if (!isNaN(x)) vals = Array.concat(vals, x); } }
        gm = NaN; gs = NaN; if (vals.length > 0) Array.getStatistics(vals, mn, mx, gm, gs); if (vals.length < 2) gs = NaN;
        stName = "not aggregated"; if (st == 1) stName = "aggregated";
        summary = summary + rNames[q] + "\t" + condNames[c] + "\t" + stName + "\t" + d2s(gm, 4) + "\t" + d2s(gs, 4) + "\t" + vals.length + "\n";
    }
}
cellRows = "Condition\tReplicate\tFile\tSeries\tCell\tStatus\tTouches edge\tArea (um2)\tAggregated\tAggregates\tPuncta\tMean punctum area (um2)\tAggregate area (um2)"
    + "\tShare of protein in aggregates\tShare of protein in puncta";
if (hasOrg) cellRows = cellRows + "\tPearson (protein vs organelle)\tManders M1 (protein on organelle)\tEvenness on organelle (CV)";
if (do3D) cellRows = cellRows + "\tAggregated 3D\tAggregates 3D\tPuncta 3D\tMean punctum volume 3D (um3)";
if (exo) cellRows = cellRows + "\tOrganelle carrying the protein (share)\tProtein level (x background noise)";
cellRows = cellRows + "\n";
for (k = 0; k < cImg.length; k++) {
    i = cImg[k];
    eTxt = "no"; if (cEdge[k]) eTxt = "yes"; aTxt = "no"; if (cIsAgg[k]) aTxt = "yes";
    cellRows = cellRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + cLabel[k] + "\t" + cStatus[k] + "\t" + eTxt + "\t" + d2s(cArea[k], 2)
        + "\t" + aTxt + "\t" + cAgg[k] + "\t" + cPun[k] + "\t" + d2s(cMeanA[k], 4) + "\t" + d2s(cAggA[k], 4) + "\t" + d2s(cShA[k], 4) + "\t" + d2s(cShP[k], 4);
    if (hasOrg) cellRows = cellRows + "\t" + d2s(cPear[k], 4) + "\t" + d2s(cM1[k], 4) + "\t" + d2s(cCV[k], 4);
    if (do3D) { a3t = "-"; if (cIsAgg3[k] == 1) a3t = "yes"; if (cIsAgg3[k] == 0) a3t = "no"; cellRows = cellRows + "\t" + a3t + "\t" + d2s(cAgg3[k], 0) + "\t" + d2s(cObj3[k], 0) + "\t" + d2s(cVol3[k], 4); }
    if (exo) cellRows = cellRows + "\t" + d2s(cLg[k], 4) + "\t" + d2s(cLev[k], 3);
    cellRows = cellRows + "\n";
}
imgRows = "Condition\tReplicate\tFile\tSeries\tCells measured\tCells excluded";
for (q = 0; q < nK; q++) if (readoutShown(q, hasOrg, do3D, exo)) imgRows = imgRows + "\t" + rNames[q];
imgRows = imgRows + "\tPixel size (um)\tSlices\n";
for (i = 0; i < nI; i++) {
    imgRows = imgRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + iCells[i] + "\t" + iOut[i];
    for (q = 0; q < nK; q++) if (readoutShown(q, hasOrg, do3D, exo)) imgRows = imgRows + "\t" + d2s(iv[q * nI + i], 4);
    imgRows = imgRows + "\t" + d2s(iPx[i], 4) + "\t" + iNz[i] + "\n";
}
repRows = "Condition\tReplicate\tImages\tCells measured\tAggregated cells (%)\tAggregates per cell";
if (hasOrg) repRows = repRows + "\tPearson (protein vs organelle)\tManders M1 (protein on organelle)\tEvenness on organelle (CV)";
repRows = repRows + "\n";
for (c = 0; c < nCond; c++) {
    reps = newArray();
    for (i = 0; i < nI; i++) if (iCond[i] == c) reps = Array.concat(reps, iRep[i]);
    reps = uniqueOf(reps);
    for (r = 0; r < reps.length; r++) {
        nn = 0; nc = 0;
        for (i = 0; i < nI; i++) if (iCond[i] == c) { if (iRep[i] == reps[r]) { nn++; nc += iCells[i]; } }
        repRows = repRows + condNames[c] + "\t" + reps[r] + "\t" + nn + "\t" + nc;
        qs = newArray(0, 1, 6, 7, 8); nq = 2; if (hasOrg) nq = 5;
        for (j = 0; j < nq; j++) { v = Array.slice(iv, qs[j] * nI, (qs[j] + 1) * nI); repRows = repRows + "\t" + d2s(repMean(v, iCond, iRep, c, reps[r]), 4); }
        repRows = repRows + "\n";
    }
}
// zoom check: puncta counts and sizes depend on the pixel size
Array.getStatistics(iPx, pxMin, pxMax);
zoomNote = "";
if (pxMax > 1.2 * pxMin) zoomNote = "Pixel sizes differ between images (" + d2s(pxMin, 3) + " to " + d2s(pxMax, 3) + " um): puncta counts and sizes are not directly comparable between zooms (Images sheet: pixel size). Pearson, Manders and evenness depend much less on zoom.";
aggRule = "\nAggregates\tpuncta of at least " + cut + " um2 AND at least " + bright + " x the median punctum brightness of the same cell (set in the aggregate window; start " + d2s(cutStart, 2) + " um2 and " + d2s(brightStart, 2) + " x, just above the brightest control object of that size). Dense normal puncta can merge into objects as big as an aggregate; an aggregate is also denser";
aggCell = "\nAggregated cell\tat least " + minAgg + " aggregate(s)";
if (exo) {
    aggRule = "\nOrganelle coverage\tshare of the cell's organelle (max projection of its 3D outline) carrying the protein; the protein is outlined per cell (Otsu of the cell's background-subtracted sum over the slices, 1-pixel Gaussian), so bright and dim cells are judged alike"
        + "\nTransfected cells\tmean protein per voxel (background-subtracted) at least " + minLevel + " x the background noise (SD outside the cells); dimmer cells are untransfected: listed, not measured";
    aggCell = "\nAggregated cell\tat least " + d2s(cut, 1) + "% of its organelle carries no protein: the protein has left the organelle for a few rods, rings or masses (set in the aggregate window; start " + d2s(cutStart, 1) + "%, just above the highest transfected control cell). Its outlined protein is reported as the aggregate"
        + "\nExpression bins\ttertiles of the protein level of all measured cells; overexpressed protein can self-aggregate at high levels, so compare conditions within a bin";
}
settings = "Setting\tValue\nPlugin\tConfocal Workflows " + pluginVersion() + "\nAnalysis\t" + mode + "; " + analysis + "\nProtein\t" + origin + "\n";
if (compare) for (g = 0; g < nCond; g++) settings = settings + condNames[g] + " folder\t" + dirs[g] + "\n";
else settings = settings + "Input\t" + fPath[0] + "\n";
settings = settings + "Protein channel\t" + protCh + "\nOrganelle\t" + orgCh + "\nNuclei\t" + nucCh + "\nCells outlined with\t" + outlineCh
    + "\nCells\t"; if (whole) settings = settings + "whole field = one cell"; else settings = settings + "outline channel max projection, Gaussian 1 um, " + cellMethod + " threshold, holes filled; split halfway between nuclei (Voronoi; nuclei: " + nucMethod + " threshold); a cell needs >= " + minNuc + " um2 of its own nucleus; minimum " + minCell + " um2";
settings = settings + "\nCells cut by the image edge\t"; if (excludeEdge) settings = settings + "excluded"; else settings = settings + "measured and flagged";
settings = settings
    + "\nPuncta\tprotein max projection, rolling ball " + bgRadius + " um, 1-pixel Gaussian, remaining background (median below Otsu) set to 0; threshold " + T + " (" + method + "; methods scored on " + nRef + " " + condNames[0] + " image(s), applied unchanged to all); at least " + minPunct + " um2"
    + "\nSplitting\ttouching puncta are split at their necks (binary watershed) before sizes are measured, so a chain of puncta along a tubule is not one big object; a round aggregate has no neck and stays whole (2D; 3D objects are not split)"
    + aggRule
    + aggCell
    + "\nFalse-positive check\t" + d2s(fp, 2) + "% of the " + condNames[0] + " cells are called aggregated at this cutoff (pooled cells); it should be close to 0 when the control has no aggregates"
    + "\nShare of protein in aggregates / puncta\tbackground-subtracted protein (sum over the slices) inside the aggregate / punctum outlines / in the whole cell";
if (do3D && exo) settings = settings + "\n3D\tpuncta counted on the prepared stack >= " + T3 + " (3D Objects Counter); the aggregated call is made in 2D only";
if (do3D && !exo) settings = settings + "\n3D\tprepared stack >= " + T3 + " (the 2D threshold, but at least 5x the noise of single slices = " + d2s(5 * noise3, 3) + "); 3D Objects Counter; aggregates >= " + d2s(volCut, 4) + " um3 (sphere with a " + cut + " um2 cross-section) and >= " + bright + " x the median 3D object brightness of the same cell; objects assigned to the cell containing their centre";
if (hasOrg) settings = settings
    + "\nOrganelle\tprepared per slice (rolling ball " + orgRadius + " um, 1-pixel Gaussian, remaining background set to 0), threshold " + d2s(Torg, 3) + " (Otsu, median of the " + condNames[0] + " stacks), applied to all slices of all images"
    + "\nCell voxels\tthe outline channel with a 3D Gaussian (1 um, 1 slice) and Otsu in every slice (whole field: every voxel)"
    + "\nPearson\tprotein vs organelle (both background-subtracted) over the cell's voxels: falls when the protein leaves an even coat of the organelle for a few foci"
    + "\nManders M1\tshare of the cell's protein (background-subtracted) inside the organelle outline: stays high when the protein aggregates on the organelle, falls when it is released from it"
    + "\nEvenness (CV)\tSD / mean of the protein inside the organelle outline: rises as the protein gathers into foci"
    + "\nMitoTracker\tdepends on membrane potential; a change in it changes Pearson without any change in the protein (TOM20 does not)";
if (zoomNote != "") settings = settings + "\nZoom\t" + zoomNote;
settings = settings + "\nStatistics unit\t" + unitName + " (image value = mean of its measured cells; % aggregated = share of its cells)\nImages measured\t" + nI + "\n";
xlsx = outDir + "aggregates_results.xlsx";
err = writeXlsx(xlsx, newArray("Summary", "Replicates", "Images", "Cells", "Threshold methods", "Settings"),
    newArray(summary, repRows, imgRows, cellRows, methodRows, settings));
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
total = 0; for (i = 0; i < nI; i++) total += iCells[i];
rule = "aggregates >= " + d2s(cut, 3) + " um2 and >= " + d2s(bright, 2) + " x the median punctum";
if (exo) rule = "aggregated = >= " + d2s(cut, 1) + "% of the organelle without protein";
nDim = 0; for (k = 0; k < nC; k++) if (cStatus[k] == "too dim (untransfected)") nDim++;
done = "Measured " + total + " cells in " + nI + " images; puncta threshold " + d2s(T, 2) + " (" + method + "); " + rule + ".\n"
    + d2s(fp, 1) + "% of the " + condNames[0] + " cells are called aggregated (false-positive check).\n \nResults:  " + xlsx;
if (graphs.length > 0) done = done + "\nBar graphs:  " + outDir + "bar_graphs.png";
done = done + "\nQC images:  " + qcDir + "\n \nStatistics use " + unitName + ", not pooled cells.";
if (exo) done = done + "\n" + nDim + " cell(s) too dim to count as transfected (Cells sheet).";
if (zoomNote != "") done = done + "\n \n" + zoomNote;
if (noBgList != "") done = done + "\n \nLittle cell-free background (under 2% of the field), so the protein background is less certain in:\n" + noBgList;
if (skipped != "") done = done + "\n \nNot processed:\n" + skipped + "A file listed here that should match the others is most likely damaged.";
if (graphs.length > 0 && interactive) open(outDir + "bar_graphs.png");
print("Done. " + done);
if (interactive) showMessage("Aggregates finished", done);

// ================= functions (aggregates) =================

// Which readouts apply: organelle readouts (6-8) need an organelle, 3D ones (9-12) the 3D analysis, 13-14 the
// exogenous branch.
function readoutShown(q, hasOrg, do3D, exo) {
    if (!hasOrg && q >= 6 && q <= 8) return false;
    if (!do3D && q >= 9 && q <= 12) return false;
    if (!exo && q >= 13) return false;
    return true;
}

// Exogenous rule. For each cell (cellLabels 1..nCells): the share of its organelle (org2d, 0/1) that carries the
// protein, the protein being outlined per cell (Otsu of the cell's smoothed sumTitle), so bright and dim cells are
// judged alike. NaN for a cell without organelle. Writes outLab (16-bit): each cell's protein pixels = its number.
function organelleCoverage(sumTitle, org2d, nCells, outLab) {
    selectWindow(sumTitle); run("Select None"); run("Duplicate...", "title=cov_s"); run("Gaussian Blur...", "sigma=1");
    W = getWidth(); H = getHeight();
    newImage("cov_t", "32-bit black", W, H, 1);
    for (ci = 0; ci < nCells; ci++) {
        cellSelect(ci); selectWindow("cov_s"); run("Restore Selection");
        setAutoThreshold("Otsu dark"); getThreshold(lo, hi); resetThreshold(); run("Select None");
        selectWindow("cov_t"); run("Restore Selection"); run("Set...", "value=" + lo); run("Select None");
    }
    imageCalculator("Subtract create 32-bit", "cov_s", "cov_t"); rename("cov_d");
    setThreshold(1e-6, 1e30); run("Convert to Mask"); run("32-bit"); run("Divide...", "value=255"); rename("cov_p");
    selectWindow("cellLabels"); run("Select None"); run("Duplicate...", "title=cov_l"); run("32-bit");
    imageCalculator("Multiply create 32-bit", "cov_p", "cov_l"); rename(outLab); scl = call("ij.process.ImageConverter.getDoScaling"); setOption("ScaleConversions", false); run("16-bit"); setOption("ScaleConversions", scl == "true");
    imageCalculator("Multiply create 32-bit", "cov_p", org2d); rename("cov_po");
    cov = newArray(nCells);
    for (ci = 0; ci < nCells; ci++) { o = roiVal(org2d, ci); cov[ci] = NaN; if (o > 0) cov[ci] = roiVal("cov_po", ci) / o; }
    close("cov_s"); close("cov_t"); close("cov_p"); close("cov_l"); close("cov_po");
    return cov;
}

// Organelle outline in 2D (0/1, 32-bit) named outTitle. With radius > 0: prepares a copy of the stack src (rolling
// ball, as in the measurement) and thresholds it at T; with radius 0, src is already a 0/1 stack. Max projection.
function orgMask2D(src, radius, T, outTitle) {
    selectWindow(src); run("Duplicate...", "title=om_tmp duplicate");
    if (radius > 0) { b = prepare("om_tmp", radius); selectWindow("om_tmp"); setThreshold(T, 1e30); run("Convert to Mask", "background=Dark black"); run("Divide...", "value=255 stack"); run("32-bit"); }
    projectTo("om_tmp", outTitle); close("om_tmp");
}

// Brightness of each object relative to the median object of its own cell ("cellLabels"; x, y in pixels).
// Objects outside every cell are compared with the median of all objects. Normalising per cell keeps the
// remaining, dimmer puncta of an aggregated cell from making a neighbour's normal puncta look bright.
function perCellRatio(means, xs, ys) {
    n = means.length; out = newArray(n); cell = newArray(n);
    if (n == 0) return out;
    selectWindow("cellLabels");
    for (i = 0; i < n; i++) cell[i] = getPixel(floor(xs[i]), floor(ys[i]));
    all = medianOf(means);
    Array.getStatistics(cell, cmin, cmax);
    med = newArray(cmax + 1);
    for (c = 0; c <= cmax; c++) {
        v = newArray();
        for (i = 0; i < n; i++) if (cell[i] == c) { x = means[i]; v = Array.concat(v, x); }
        med[c] = all; if (c > 0 && v.length > 0) med[c] = medianOf(v);
    }
    for (i = 0; i < n; i++) { c = cell[i]; out[i] = means[i] / med[c]; }
    return out;
}

// Live aggregate window on "sizeprev" (puncta labels in "sizelab"; per slice "area:brightness," for every label in
// objs, separated by ";"). Normal puncta yellow, puncta >= both cutoffs red; the sliders, typed values or clicks on
// structures (the cutoffs become the smallest and dimmest clicked) set them. Returns "size<tab>brightness",
// "cancel" or "ERR ...".
// labA / labB: slider labels; labB "" = one slider only (the second value stays 1).
function sizeDialog(title, msg, objs, start, maxA, startB, maxB, labA, labB) {
    msg = replace(msg, "'", ""); title = replace(title, "'", "");
    msg = replace(msg, "\n", "\\n");
    js = "try { var W = Packages.ij.WindowManager; var imp = W.getImage('sizeprev'); var lab = W.getImage('sizelab');"
       + "var S = '" + objs + "'.split(';'); var A = [], B = []; for (var i = 0; i < S.length; i++) { var p = S[i].split(','); var a = [], b = [];"
       + "  for (var j = 0; j < p.length; j++) if (p[j] != '') { var q = p[j].split(':'); a.push(parseFloat(q[0])); b.push(parseFloat(q[1])); } A.push(a); B.push(b); }"
       + "var gd = new Packages.ij.gui.NonBlockingGenericDialog('" + title + "');"
       + "gd.addMessage('" + msg + "');"
       + "gd.addSlider('" + labA + "', 0, " + maxA + ", " + start + ", " + (maxA / 1000) + ");"
       + "var two = " + (labB != "") + "; if (two) gd.addSlider('" + labB + "', 1, " + maxB + ", " + startB + ", 0.01);"
       + "var cs = " + start + ", cb = " + startB + ", last = imp.getCurrentSlice(), pa = [], pb = [];"
       + "var BP = Packages.ij.process.ByteProcessor, TS = Packages.ij.plugin.filter.ThresholdToSelection, NL = Packages.ij.process.ImageProcessor.NO_LUT_UPDATE;"
       + "function show(c, d) { cs = c; cb = d; var k = imp.getCurrentSlice(); var lp = lab.getStack().getProcessor(k); var a = A[k - 1] || [], b = B[k - 1] || [];"
       + "  var w = lp.getWidth(), h = lp.getHeight(), big = new BP(w, h), small = new BP(w, h);"
       + "  for (var i = 0; i < w * h; i++) { var v = lp.get(i); if (v > 0) { if (a[v - 1] >= c && b[v - 1] >= d) big.set(i, 255); else small.set(i, 255); } }"
       + "  var ov = new Packages.ij.gui.Overlay(); big.setThreshold(255, 255, NL); small.setThreshold(255, 255, NL);"
       + "  var rs = new TS().convert(small), rb = new TS().convert(big);"
       + "  if (rs != null) { rs.setStrokeColor(java.awt.Color.YELLOW); ov.add(rs); } if (rb != null) { rb.setStrokeColor(java.awt.Color.RED); rb.setStrokeWidth(2); ov.add(rb); }"
       + "  imp.setOverlay(ov); }"
       + "var lis = new Packages.ij.ImageListener({ imageOpened: function (i) {}, imageClosed: function (i) {},"
       + "  imageUpdated: function (i) { if (i == imp && imp.getCurrentSlice() != last) { last = imp.getCurrentSlice(); show(cs, cb); } } });"
       + "Packages.ij.ImagePlus.addImageListener(lis); show(cs, cb);"
       + "var tf = gd.getNumericFields();"
       + "var ml = new java.awt.event.MouseAdapter({ mouseClicked: function (e) { var cv = imp.getCanvas(); var x = cv.offScreenX(e.getX()), y = cv.offScreenY(e.getY());"
       + "  var k = imp.getCurrentSlice(); var v = lab.getStack().getProcessor(k).get(x, y); var a = A[k - 1] || [], b = B[k - 1] || [];"
       + "  if (v > 0 && a[v - 1] != null) { pa.push(a[v - 1]); pb.push(b[v - 1]); var m = 0.8 * Math.min.apply(null, pa), n = Math.max(1, 0.8 * Math.min.apply(null, pb));"
       + "    if (!two) n = 1; tf.get(0).setText(String(Math.round(m * 1000) / 1000)); if (two) tf.get(1).setText(String(Math.round(n * 100) / 100)); show(m, n); } } });"
       + "gd.addDialogListener(new Packages.ij.gui.DialogListener({ dialogItemChanged: function (g, e) {"
       + "  var t = parseFloat(tf.get(0).getText()), u = two ? parseFloat(tf.get(1).getText()) : 1; if (!isNaN(t) && !isNaN(u)) show(t, u); return true; } }));"
       + "var w = imp.getWindow(); var ss = java.awt.Toolkit.getDefaultToolkit().getScreenSize(); var sw = ss.width, sh = ss.height;"
       + "if (w != null) { var z = Math.min(1, Math.min(0.55 * sw / imp.getWidth(), 0.8 * sh / imp.getHeight()));"
       + "  var cv = imp.getCanvas(); cv.addMouseListener(ml); var guard = 0; while (cv.getMagnification() > z + 1e-6 && guard++ < 20) cv.zoomOut(Math.floor(imp.getWidth() / 2), Math.floor(imp.getHeight() / 2));"
       + "  w = imp.getWindow(); w.setLocation(0, 0); gd.pack(); gd.centerDialog(false); gd.setLocation(Math.max(0, Math.min(w.getWidth() + 10, sw - gd.getWidth())), 0); }"
       + "gd.showDialog(); var out = 'cancel';"
       + "if (!gd.wasCanceled()) { var s1 = gd.getNextNumber(); var s2 = two ? gd.getNextNumber() : 1; out = s1 + '\\t' + s2; }"
       + "Packages.ij.ImagePlus.removeImageListener(lis); if (imp.getCanvas() != null) imp.getCanvas().removeMouseListener(ml); imp.setOverlay(null); out; } catch (e) { 'ERR ' + e; }";
    return eval("js", js);
}

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
        if (sx[k] < maxX / 2) out = Array.concat(out, -2);          // thumbnail / overview: skipped silently
        else if (st[k] > 1) out = Array.concat(out, -3);           // time-lapse
        else if (sok[k] == 0) out = Array.concat(out, -4);         // a plane could not be read
        else out = Array.concat(out, k);
    }
    return out;
}

// "Not processed" line for a series code from usableSeries (k = its position in the list); "" for thumbnails.
function seriesProblem(path, s, k) {
    n = File.getName(path);
    if (s == -1) return n + " is damaged (could not be read)\n";
    if (s == -3) return n + " series " + (k + 1) + " is a time-lapse (not supported): skipped\n";
    if (s == -4) return n + " series " + (k + 1) + " has a plane that could not be read: skipped\n";
    return "";
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

// Noise of a background-subtracted stack: RMS of its negative voxels (pure noise, since background is 0).
function noiseRms(title) {
    selectWindow(title);
    sq = 0; n = 0;
    for (z = 1; z <= nSlices; z++) {
        setSlice(z);
        setThreshold(-1e30, 0);
        run("Create Selection");
        if (selectionType() >= 0) { getRawStatistics(nb, mean, mn, mx, sd); sq += nb * (sd * sd + mean * mean); n += nb; }
        run("Select None");
    }
    resetThreshold();
    setSlice(1);
    if (n == 0) return 0;
    return sqrt(sq / n);
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

// Mean protein per voxel of each cell (sumTitle = background-subtracted sum over nz slices) in units of the
// background noise; NaN when the noise is unknown (whole-field mode).
function cellLevels(sumTitle, nCells, nz, noise) {
    lv = newArray(nCells);
    for (ci = 0; ci < nCells; ci++) {
        cellSelect(ci); selectWindow(sumTitle); run("Restore Selection"); getRawStatistics(n, mean); run("Select None");
        lv[ci] = NaN; if (noise > 0) lv[ci] = mean / nz / noise;
    }
    return lv;
}

// Plugin version: shown by About and written into every results file.
function pluginVersion() { return "1.0.1"; }
