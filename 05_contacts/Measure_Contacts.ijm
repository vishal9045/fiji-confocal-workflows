// Contact sites workflow: how much two organelles touch, per cell, in 3D, and (optionally) how much of a contact
// reporter sits at their contacts. Built for ER-mitochondria contacts (MAMs) with Contact-ID, but any two organelle
// markers work (ER-mito, mito-lysosome, mito-lipid droplet, PM-ER ...), with or without a reporter.
//
//   1. Choose "Control vs treated" (control folder, then one or more treated folders) or "Absolute" (one file or one
//      folder). A folder can hold the images directly or one subfolder per replicate. Any Bio-Formats format.
//   2. Channels: organelle A (e.g. TOM20), organelle B (e.g. Sec61), the contact reporter (e.g. streptavidin for
//      Contact-ID, SPLICS, split-GFP, PLA; optional), nuclei, and the channel that outlines the cells.
//   3. Cells: each nucleus seeds one cell; the outline channel gives its extent; touching cells are split halfway
//      between nuclei. Cells where A or B is dimmer than a set multiple of the background noise are untransfected
//      (listed, not measured): with split reporters both halves must be there.
//      3D (default) works on every slice. 2D works on max projections, where structures at different depths overlap
//      in the projection, so overlaps are inflated (more in thick cells or where organelles cluster): use 2D only for
//      single planes or max projections, or to match earlier max-projection results; never mix 2D and 3D numbers.
//   4. A and B are outlined in every slice (rolling ball, 1-pixel Gaussian, ONE threshold each for all images: Otsu,
//      median of the control stacks). Confocal resolution (~250 nm across, ~600 nm in z) is far coarser than a
//      contact (10-30 nm), so two markers alone measure APPOSITION: A within a set distance of B. Chance apposition
//      is what A would get if placed at random in the same cell (the share of the cell's volume within the distance
//      of B), reported alongside: crowded or swollen organelles touch more by chance alone.
//   5. Reporter (optional): its puncta are outlined with one threshold (live window on the control images). MAM
//      (contact) volume = reporter puncta within the distance of both A and B. Interface enrichment = reporter per
//      voxel on A next to B / on A away from B: a reporter that marks contacts is enriched there; signal spread
//      over the whole organelle is not (e.g. streptavidin also binds the naturally biotinylated carboxylases of
//      mitochondria in every cell). MAM volume by chance (random placement) is reported as well.
//   6. Writes contacts_results.xlsx (Summary relative to control, Replicates, Images, Cells, Settings), bar graphs and
//      qc/ images (A green, B red, reporter magenta, contacts outlined white, cells numbered; u = untransfected).
//      Statistics use replicate means when every condition has >= 2 replicate subfolders, otherwise image values.
//   7. Optional 3D view: pick an image and draw a box on it; A (green), B (red, both see-through) and their
//      contacts (white) are shown as surfaces in the 3D Viewer (rotate with the mouse) and saved to qc/<image>_3D.png.
//      Without 3D graphics, rotating projections are saved instead (qc/<image>_3D_projection.png).
//      Deconvolution (Deconvolve Confocal Stack) is optional.

// ---- settings ----
interactive = true;          // false = use the defaults below without dialogs (testing)
viewTest = -1;               // testing only: image number for the 3D view without dialogs (-1 = none)
// ------------------

requires("1.54");
setOption("BlackBackground", true);
run("Options...", "iterations=1 count=1 black");

// ---- 1. what to measure ----
modes = newArray("Control vs treated (one or more treated folders, e.g. doses)", "Absolute (no comparison)");
inputs = newArray("A folder", "One file");
analyses = newArray("3D (every slice of the stack)", "2D (max projection: overlaps are inflated, see the warning)");
mode = modes[0]; input = inputs[0]; analysis = analyses[0];
if (interactive) {
    Dialog.create("Contacts");
    Dialog.addRadioButtonGroup("Analysis", modes, 2, 1, mode);
    Dialog.addRadioButtonGroup("Measure on", analyses, 2, 1, analysis);
    Dialog.addMessage("Control vs treated: you will pick the control folder, then a treated folder; you can then add\n"
        + "more treated folders. All share the control's thresholds and one graph.\n"
        + "Absolute: measure one file or one folder on its own.\n"
        + "A folder can hold the images directly or one subfolder per replicate. Use z-stacks (deconvolved if possible).");
    Dialog.show();
    mode = Dialog.getRadioButton(); analysis = Dialog.getRadioButton();
    if (analysis == analyses[1]) showMessageWithCancel("Contacts: 2D max projection",
        "In a max projection, structures at different depths land on the same pixels: an organelle 1-2 um above\n"
        + "the other still counts as overlapping. Overlaps are therefore INFLATED, more in thick cells or where\n"
        + "organelles cluster, and differences between conditions can shrink or grow.\n \n"
        + "Use 2D only when the images are single planes or max projections, or when the results must match\n"
        + "earlier results measured on max projections. For z-stacks, use 3D. Do not mix 2D and 3D numbers.");
    if (mode == modes[1]) {
        Dialog.create("Contacts: absolute");
        Dialog.addRadioButtonGroup("Measure", inputs, 1, 2, input);
        Dialog.show();
        input = Dialog.getRadioButton();
    }
}
compare = false; if (mode == modes[0]) compare = true;
flat = false; if (analysis == analyses[1]) flat = true;
uV = "um3"; vWord = "volume"; if (flat) { uV = "um2"; vWord = "area"; }
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
if (nCh < 2) exit("The images need at least two channels (the two organelles).");
// defaults: named like the marker or shown in the usual colour (A green, B red, reporter magenta, nuclei blue as set
// in the file), otherwise the usual order (C1 nuclei, C2 A, C3 B, C4 reporter)
kA = channelLike(chNames, "tom ?20|tom ?70|mito|\\(green", minOf(1, nCh - 1));
kB = channelLike(chNames, "sec61|calnex|er|\\(red", minOf(2, nCh - 1));
kR = channelLike(chNames, "strept|splics|pla|contact|\\(magenta", minOf(3, nCh - 1));
kN = channelLike(chNames, "dapi|hoechst|405|nuc|\\(blue", 0);
NONE_R = "None (two markers only: apposition)"; NONE_NUC = "None (touching cells are not split)"; WHOLE = "Whole field (one cell per image)";
chA = chNames[kA]; chB = chNames[kB];
chR = NONE_R; if (nCh >= 4 && kR != kA && kR != kB && kR != kN) chR = chNames[kR];
nucCh = NONE_NUC; if (nCh >= 3 && kN != kA && kN != kB) nucCh = chNames[kN];
outlineCh = chB;
rChoices = Array.concat(NONE_R, chNames); nucChoices = Array.concat(NONE_NUC, chNames); outlineChoices = Array.concat(chNames, WHOLE);
nameA = "Mitochondria"; nameB = "ER"; nameR = "MAM";
cellMethod = "Triangle";
radA = 1; radB = 2; radR = 1;   // um, rolling ball per marker (about the radius of its biggest structure)
dist = 0.1;            // um: A within this distance of B counts as apposed (rounded to whole pixels in each slice; 0 = overlap only)
minLevel = 1.5;        // A and B must reach this many x the background noise in a cell (else untransfected)
minCell = 100;         // um^2
minFrac = 10;          // %: a cell with less organelle A than this share of the median cell is a fragment (e.g. a
                       // neighbour's edge cut by the outline): listed, not measured
minNuc = 50;           // um^2: smaller DAPI specks are not nuclei
nucMethod = "Otsu";    // nuclei threshold (Li catches dim nuclei next to bright ones; Otsu ignores cytoplasmic DAPI haze)
excludeEdge = false;
if (interactive) {
    Dialog.create("Contacts: options");
    if (compare) {
        for (g = 0; g < nCond; g++) {
            nf = countOf(fCond, g);
            label = "Control name"; if (g > 0) label = "Treated " + g + " name";
            Dialog.addString(label, condNames[g], 20);
            Dialog.addToSameRow(); Dialog.addMessage("(" + nf + " files)");
        }
    } else Dialog.addMessage("" + fPath.length + " file(s)");
    Dialog.addChoice("Organelle A", chNames, chA); Dialog.addToSameRow(); Dialog.addString("called", nameA, 14);
    Dialog.addChoice("Organelle B", chNames, chB); Dialog.addToSameRow(); Dialog.addString("called", nameB, 14);
    Dialog.addChoice("Contact reporter", rChoices, chR); Dialog.addToSameRow(); Dialog.addString("contacts called", nameR, 10);
    Dialog.addChoice("Nuclei", nucChoices, nucCh); Dialog.addToSameRow(); Dialog.addChoice("threshold", newArray("Otsu", "Li", "Huang", "Triangle"), nucMethod);
    Dialog.addChoice("Outline the cells with", outlineChoices, outlineCh);
    Dialog.addChoice("Cell outline threshold", getList("threshold.methods"), cellMethod);
    Dialog.addNumber("Contact distance", dist, 2, 6, "um (A within this of B; 0 = overlap of the two outlines only)");
    Dialog.addNumber("Background radius A", radA, 1, 6, "um");
    Dialog.addNumber("Background radius B", radB, 1, 6, "um");
    Dialog.addNumber("Background radius reporter", radR, 1, 6, "um");
    Dialog.addNumber("Transfected cells: A and B at least", minLevel, 1, 6, "x the background noise");
    Dialog.addNumber("Minimum cell area", minCell, 0, 6, "um2");
    Dialog.addCheckbox("Exclude cells cut by the image edge", excludeEdge);
    Dialog.show();
    if (compare) for (g = 0; g < nCond; g++) condNames[g] = Dialog.getString();
    chA = Dialog.getChoice(); nameA = Dialog.getString(); chB = Dialog.getChoice(); nameB = Dialog.getString();
    chR = Dialog.getChoice(); nameR = Dialog.getString(); nucCh = Dialog.getChoice(); nucMethod = Dialog.getChoice(); outlineCh = Dialog.getChoice();
    cellMethod = Dialog.getChoice();
    dist = Dialog.getNumber(); radA = Dialog.getNumber(); radB = Dialog.getNumber(); radR = Dialog.getNumber();
    minLevel = Dialog.getNumber(); minCell = Dialog.getNumber();
    excludeEdge = Dialog.getCheckbox();
}
for (c = 0; c < nCond; c++) condNames[c] = replace(condNames[c], "[,{}|'\t]", " ");
nameA = replace(nameA, "[,{}|'\t]", " "); nameB = replace(nameB, "[,{}|'\t]", " "); nameR = replace(nameR, "[,{}|'\t]", " ");
cA = chIndex(chA); cB = chIndex(chB); cR = chIndex(chR); cN = chIndex(nucCh);   // 0 = none
whole = false; cL = 0; if (outlineCh == WHOLE) whole = true; else cL = chIndex(outlineCh);
if (cA == cB) exit("Organelle A and B must be different channels.");
if (cR > 0 && (cR == cA || cR == cB)) exit("The contact reporter must be its own channel.");
hasR = false; if (cR > 0) hasR = true;
qcDir = outDir + "qc" + File.separator;
File.makeDirectory(qcDir);
setBatchMode(true);
skipped = "";

// ---- 3. thresholds: A and B (Otsu of every prepared control stack, median); reporter (live window) ----
TA = newArray(); TB = newArray(); refT = newArray(); hv = newArray(); hc = newArray(); sliceNoise = newArray();
methods = getList("threshold.methods"); nM = methods.length; NB = 1024; nRef = 0; nPrev = 0; maxV = 0;
for (fi = 0; fi < fPath.length; fi++) {
    if (fCond[fi] != 0) continue;
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (s == -1) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
        chs = newArray(2); chs[0] = cA; chs[1] = cB; names = newArray("chA", "chB");
        if (hasR) { chs = Array.concat(chs, cR); names = Array.concat(names, "chR"); }
        err = loadChannels(fPath[fi], s, chs, names);
        if (err != "") { skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        if (flat) flattenAll(names);
        b = prepare("chA", radA); selectWindow("chA"); setAutoThreshold("Otsu dark stack"); getThreshold(lo, hi); TA = Array.concat(TA, lo);
        b = prepare("chB", radB); selectWindow("chB"); setAutoThreshold("Otsu dark stack"); getThreshold(lo, hi); TB = Array.concat(TB, lo);
        close("chA"); close("chB");
        if (hasR) {
            projectTo("chR", "pp");
            b = prepare("pp", radR);
            b = prepare("chR", radR); nr = noiseRms("chR"); sliceNoise = Array.concat(sliceNoise, nr); close("chR");
            selectWindow("pp");
            for (m = 0; m < nM; m++) { setAutoThreshold(methods[m] + " dark"); getThreshold(lo, hi); refT = Array.concat(refT, lo); }
            resetThreshold();
            getHistogram(values, counts, NB);
            hv = Array.concat(hv, values); hc = Array.concat(hc, counts);
            maxV = maxOf(maxV, values[NB - 1]);
            if (nPrev < 6) { nPrev++; rename("ref" + nPrev); } else close("pp");
        }
        nRef++;
    }
}
if (nRef == 0) exit("None of the " + condNames[0] + " images could be read.\n" + skipped);
thrA = medianOf(TA); thrB = medianOf(TB);
TR = NaN; TR3 = NaN; methodR = "-";
if (hasR) {
    noise3 = 0; if (sliceNoise.length > 0) noise3 = medianOf(sliceNoise);
    mT = newArray(nM); otsu = 0;
    for (m = 0; m < nM; m++) {
        t = newArray(nRef);
        for (r = 0; r < nRef; r++) t[r] = refT[r * nM + m];
        mT[m] = medianOf(t);
        if (methods[m] == "Otsu") otsu = m;
    }
    byValue = Array.rankPositions(mT);
    order = newArray(1); order[0] = otsu;
    for (k = 0; k < nM; k++) if (byValue[k] != otsu) order = Array.concat(order, byValue[k]);
    labels = newArray(nM); ordT = newArray(nM);
    for (k = 0; k < nM; k++) {
        m = order[k]; ordT[k] = mT[m]; pct = 0;
        for (r = 0; r < nRef; r++) { st = scoreThreshold(hv, hc, r * NB, NB, mT[m]); pct = pct + st[1] / nRef; }
        labels[k] = methods[m] + ":  " + d2s(mT[m], 1) + "   (" + d2s(pct, 1) + "% of the image outlined)";
        if (k == 0) labels[k] = labels[k] + "  default";
    }
    TR = ordT[0]; methodR = methods[order[0]];
    if (nPrev > 1) run("Images to Stack", "method=[Copy (center)] name=preview title=ref use");
    else { selectWindow("ref1"); rename("preview"); }
    if (interactive) {
        selectWindow("preview"); run("Grays"); run("Enhance Contrast", "saturated=0.35"); setBatchMode("show");
        msg = "Every threshold method was tried on the contact reporter of " + nRef + " " + condNames[0] + " image(s) (prepared max projections).\n"
            + "Default: Otsu; the other methods are listed from low to high.\n"
            + "Yellow outlines = what counts as reporter puncta: every punctum should be outlined, the haze between them not.\n"
            + "Type a value, move the slider or pick a method; scroll the image to check the other images.\n"
            + "This one value is applied to every slice of every image.";
        r = thresholdDialog("Contacts: reporter threshold", msg, labels, ordT, maxV);
        if (r == "cancel") exit;
        if (startsWith(r, "ERR")) exit("Threshold window failed: " + r);
        f = split(r, "\t"); TR = parseFloat(f[0]); methodR = methods[order[parseInt(f[1])]];
        if (f[2] == "1") methodR = methodR + " (edited)";
    }
    close("preview");
    TR3 = maxOf(TR, 5 * noise3);   // single slices are noisier than a projection
}
print(nameA + " threshold " + d2s(thrA, 2) + ", " + nameB + " threshold " + d2s(thrB, 2) + "; reporter " + d2s(TR3, 2) + " (" + methodR + ")");

// ---- 4. measure every cell of every image ----
keys = newArray("app", "appR", "appE", "mamV", "mamA", "mamE", "pref", "shR", "nMam", "volA", "volB", "levA", "levB", "ovl");
rNames = newArray("Apposition (share of " + nameA + " within the distance of " + nameB + ")", "Apposition at random (share of the cell within the distance of " + nameB + ")",
    "Apposition enrichment (measured / random)", nameR + " " + vWord + " (" + uV + " per cell)", nameR + " " + vWord + " per " + nameA + " " + vWord,
    nameR + " enrichment (reporter at " + nameA + "-" + nameB + " interfaces / at random)", "Reporter preference for the interface (per " + nameA + " signal, interface / away)",
    "Share of the reporter at " + nameR + "s", nameR + " puncta per cell", nameA + " " + vWord + " (" + uV + ")", nameB + " " + vWord + " (" + uV + ")",
    nameA + " level (x background noise)", nameB + " level (x background noise)", nameA + "-" + nameB + " apposition " + vWord + " (" + uV + " per cell)");
nK = keys.length;
iCond = newArray(); iRep = newArray(); iFile = newArray(); iSer = newArray(); iPath = newArray(); iPx = newArray(); iNz = newArray(); iDz = newArray();
cImg = newArray(); cLabel = newArray(); cEdge = newArray(); cArea = newArray(); cVal = newArray();   // cVal[k * nK + q]
noBgList = "";
for (fi = 0; fi < fPath.length; fi++) {
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (s == -1 && fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
        chs = newArray(2); chs[0] = cA; chs[1] = cB; names = newArray("chA", "chB");
        if (hasR) { chs = Array.concat(chs, cR); names = Array.concat(names, "chR"); }
        if (cN > 0) { chs = Array.concat(chs, cN); names = Array.concat(names, "nucch"); }
        if (!whole && cL != cA && cL != cB && cL != cR && cL != cN) { chs = Array.concat(chs, cL); names = Array.concat(names, "cellch"); }
        err = loadChannels(fPath[fi], s, chs, names);
        if (err != "") { if (fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        if (flat) flattenAll(names);
        outlineSrc = "chB"; if (cL == cA) outlineSrc = "chA"; if (cL == cR && hasR) outlineSrc = "chR"; if (cL == cN && cN > 0) outlineSrc = "nucch"; if (isOpen("cellch")) outlineSrc = "cellch";
        name = File.getName(fPath[fi]);
        cname = condNames[fCond[fi]];
        qb = qcBase(cname, fRep[fi], name, s, use.length);
        selectWindow("chA"); getVoxelSize(pw, ph, pd, unit); nz = nSlices; W = getWidth(); H = getHeight();
        nCells = segmentCells(outlineSrc, cN, whole, minCell, minNuc, cellMethod, nucMethod, 0, pw);
        // background (median outside the cells) and noise of each channel
        bgA = 0; bgB = 0; bgR = 0; nzA = NaN; nzB = NaN;
        if (!whole) {
            o = outsideStats("chA", "cellmask", 2 / pw); bgA = o[0]; nzA = o[1]; if (o[2] < 0.02) noBgList = noBgList + name + "\n";
            o = outsideStats("chB", "cellmask", 2 / pw); bgB = o[0]; nzB = o[1];
            if (hasR) { o = outsideStats("chR", "cellmask", 2 / pw); bgR = o[0]; }
        }
        selectWindow("chA"); run("Subtract...", "value=" + bgA + " stack"); sumOf("chA", "sA");
        selectWindow("chB"); run("Subtract...", "value=" + bgB + " stack"); sumOf("chB", "sB");
        levA = cellLevels("sA", nCells, nz, nzA); levB = cellLevels("sB", nCells, nz, nzB);
        // the cell in 3D (outline channel, 3D Gaussian 1 um, Otsu over the stack): the space a random placement could use
        if (whole) { newImage("c3", "8-bit white", W, H, nz); }
        else {
            selectWindow(outlineSrc); run("Duplicate...", "title=c3 duplicate"); sg = maxOf(1, 1 / pw);
            if (nz > 1) run("Gaussian Blur 3D...", "x=" + sg + " y=" + sg + " z=1"); else run("Gaussian Blur...", "sigma=" + sg);
            setAutoThreshold("Otsu dark stack"); run("Convert to Mask", "background=Dark black");
        }
        // masks (0/255, every slice): A, B, both grown by the contact distance (in the plane of each slice)
        rPix = maxOf(0, round(dist / pw));   // 0 = overlap only
        selectWindow("chA"); run("Duplicate...", "title=araw duplicate"); projectTo("araw", "qAmax");
        selectWindow("chB"); run("Duplicate...", "title=qB duplicate"); projectTo("qB", "qBmax"); close("qB");
        b = prepare("chA", radA); selectWindow("chA"); setThreshold(thrA, 1e30); run("Convert to Mask", "background=Dark black"); rename("mA");
        b = prepare("chB", radB); selectWindow("chB"); setThreshold(thrB, 1e30); run("Convert to Mask", "background=Dark black"); rename("mB");
        selectWindow("mB"); run("Duplicate...", "title=dB duplicate"); if (rPix > 0) run("Maximum...", "radius=" + rPix + " stack");
        selectWindow("mA"); run("Duplicate...", "title=dA duplicate"); if (rPix > 0) run("Maximum...", "radius=" + rPix + " stack");
        // apposition zone = A within the distance of B; A away from B; the cell's space within the distance of B
        imageCalculator("AND create stack", "mA", "dB"); rename("zone");
        imageCalculator("Subtract create stack", "mA", "dB"); rename("away");
        imageCalculator("AND create stack", "dB", "c3"); rename("bc3");
        sumMask("mA", "sVA"); sumMask("mB", "sVB"); sumMask("zone", "sVZ"); sumMask("c3", "sVC"); sumMask("bc3", "sVBC");
        close("bc3");
        if (hasR) {
            selectWindow("chR"); run("Subtract...", "value=" + bgR + " stack"); run("Duplicate...", "title=rraw duplicate");
            projectTo("rraw", "qRmax"); sumOf("rraw", "sR");
            b = prepare("chR", radR); selectWindow("chR"); setThreshold(TR3, 1e30); run("Convert to Mask", "background=Dark black"); rename("mR");
            // interface = within the distance of both A and B (inside the cell); contacts (MAMs) = reporter puncta there
            imageCalculator("AND create stack", "dA", "dB"); rename("ifc"); imageCalculator("AND stack", "ifc", "c3");
            imageCalculator("AND create stack", "mR", "ifc"); rename("mam");
            imageCalculator("AND create stack", "mR", "c3"); rename("rc3");
            sumMask("mam", "sVM"); sumMask("ifc", "sVI"); sumMask("rc3", "sVRC");
            // reporter per A signal at the interface and away from it (A itself is the reference: geometry and the
            // dimmer edges of A cancel out)
            sumWeighted("rraw", "zone", "sRZ"); sumWeighted("rraw", "away", "sRW"); sumWeighted("rraw", "mam", "sRM");
            sumWeighted("araw", "zone", "sAZ"); sumWeighted("araw", "away", "sAW");
            projectTo("mam", "mamMax");
            close("rc3"); close("ifc");
        }
        // per cell
        for (ci = 0; ci < nCells; ci++) {
            cellSelect(ci); getSelectionBounds(bx, by, bw, bh); run("Select None");
            edge = false; if (!whole && (bx <= 0 || by <= 0 || bx + bw >= W || by + bh >= H)) edge = true;
            A = roiSum("nuc01", ci); nPix = A[0]; nucPix = A[1];
            if (cN > 0 && !whole && nucPix * pw * ph < minNuc) continue;   // no nucleus of its own: not a cell
            vox = pw * ph * pd; if (flat) vox = pw * ph;
            vA = roiVal("sVA", ci); vB = roiVal("sVB", ci); vZ = roiVal("sVZ", ci); vC = roiVal("sVC", ci); vBC = roiVal("sVBC", ci);
            v = newArray(nK); for (q = 0; q < nK; q++) v[q] = NaN;
            if (vA > 0) v[0] = vZ / vA;
            if (vC > 0) v[1] = vBC / vC;
            if (v[1] > 0) v[2] = v[0] / v[1];
            v[9] = vA * vox; v[10] = vB * vox; v[11] = levA[ci]; v[12] = levB[ci]; v[13] = vZ * vox;
            if (hasR) {
                vM = roiVal("sVM", ci); vI = roiVal("sVI", ci); vRC = roiVal("sVRC", ci);
                v[3] = vM * vox; if (vA > 0) v[4] = vM / vA;
                if (vRC > 0 && vI > 0 && vC > 0) v[5] = (vM / vRC) / (vI / vC);
                rZ = roiVal("sRZ", ci); rW = roiVal("sRW", ci); aZ = roiVal("sAZ", ci); aW = roiVal("sAW", ci); rT = roiVal("sR", ci);
                if (aZ > 0 && aW > 0 && rW > 0) v[6] = (rZ / aZ) / (rW / aW);
                if (rT > 0) v[7] = roiVal("sRM", ci) / rT;
                cellSelect(ci); selectWindow("mamMax"); run("Restore Selection");
                run("Analyze Particles...", "size=0-Infinity pixel display clear"); v[8] = nResults; run("Clear Results");
                selectWindow("mamMax"); run("Select None");
            }
            label = ci + 1; imgNo = iCond.length; area = nPix * pw * ph;
            cImg = Array.concat(cImg, imgNo); cLabel = Array.concat(cLabel, label); cEdge = Array.concat(cEdge, edge); cArea = Array.concat(cArea, area);
            cVal = Array.concat(cVal, v);
        }
        // QC: A green, B red, reporter magenta (max projections), contacts white, apposition zone cyan, cells numbered
        selectWindow("qAmax"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        selectWindow("qBmax"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        if (hasR) { selectWindow("qRmax"); run("Enhance Contrast", "saturated=0.35"); run("8-bit"); run("Merge Channels...", "c1=qBmax c2=qAmax c6=qRmax create"); }
        else run("Merge Channels...", "c1=qBmax c2=qAmax create");
        run("RGB Color"); rename("qc"); close("Composite");
        projectTo("zone", "zoneMax");
        drawOutline("qc", "zoneMax", 0, 220, 255, false); close("zoneMax");
        if (hasR) drawOutline("qc", "mamMax", 255, 255, 255, false);
        if (isOpen("nucmask")) drawOutline("qc", "nucmask", 150, 150, 150, false);
        for (ci = 0; ci < nCells; ci++) {
            cellSelect(ci); selectWindow("qc"); run("Restore Selection");
            Roi.getBounds(lx, ly, lw, lh); setForegroundColor(255, 255, 255); run("Draw", "slice"); run("Select None");
            tag = "" + (ci + 1); if (levA[ci] < minLevel || levB[ci] < minLevel) tag = tag + " u";
            setFont("SansSerif", maxOf(14, round(W / 45)), "bold antialiased"); setColor(255, 255, 255); drawString(tag, lx + lw / 2, ly + lh / 2);
        }
        legend = "green: " + nameA + "   red: " + nameB; if (hasR) legend = legend + "   magenta: reporter   white: " + nameR + "s";
        legend = legend + "   cyan: " + nameA + " within " + d2s(rPix * pw, 2) + " um of " + nameB; if (rPix == 0) legend = legend + " (overlap)";
        legend = legend + "   u = untransfected";
        setFont("SansSerif", maxOf(12, round(W / 70)), "antialiased"); setColor(255, 255, 255); drawString(legend, 5, maxOf(14, round(W / 70)) + 4);
        saveAs("PNG", qcDir + qb + "_qc.png");
        iCond = Array.concat(iCond, fCond[fi]); iRep = Array.concat(iRep, fRep[fi]); iFile = Array.concat(iFile, name); iSer = Array.concat(iSer, s + 1); iPath = Array.concat(iPath, fPath[fi]);
        iPx = Array.concat(iPx, pw); iNz = Array.concat(iNz, nz); iDz = Array.concat(iDz, pd);
        print(cname + " / " + name + ": " + nCells + " cell outline(s)");
        close("*");
    }
}
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }
if (iCond.length == 0) exit("No image could be measured.\n" + skipped);
nC = cImg.length;
if (nC == 0) exit("No cells were found. Check the channels and the qc/ images.\n" + skipped);

// ---- 5. status per cell; image values = means of their measured cells ----
cStatus = newArray(nC);
va = newArray(); for (k = 0; k < nC; k++) { x = cVal[k * nK + 9]; if (!isNaN(x)) va = Array.concat(va, x); }
medVA = 0; if (va.length > 0) medVA = medianOf(va);
for (k = 0; k < nC; k++) {
    cStatus[k] = "measured";
    if (cVal[k * nK + 9] < minFrac / 100 * medVA) cStatus[k] = "too little " + nameA + " (cell fragment?)";
    la = cVal[k * nK + 11]; lb = cVal[k * nK + 12];
    if ((!isNaN(la) && la < minLevel) || (!isNaN(lb) && lb < minLevel)) cStatus[k] = "too dim (untransfected)";
    if (excludeEdge && cEdge[k]) cStatus[k] = "cut by the image edge";
}
nI = iCond.length; iv = newArray(nK * nI); iCells = newArray(nI); iOut = newArray(nI);
for (i = 0; i < nI; i++) {
    for (q = 0; q < nK; q++) {
        sum = 0; n = 0;
        for (k = 0; k < nC; k++) {
            if (cImg[k] != i) continue;
            if (cStatus[k] != "measured") { if (q == 0) iOut[i] = iOut[i] + 1; continue; }
            if (q == 0) iCells[i] = iCells[i] + 1;
            x = cVal[k * nK + q];
            if (!isNaN(x)) { sum += x; n++; }
        }
        iv[q * nI + i] = NaN; if (n > 0) iv[q * nI + i] = sum / n;
    }
    msgI = condNames[iCond[i]] + " / " + iFile[i] + ": " + iCells[i] + " cells, apposition " + d2s(iv[i], 3) + " (random " + d2s(iv[nI + i], 3) + ")";
    if (hasR) msgI = msgI + ", " + nameR + " " + d2s(iv[3 * nI + i], 1) + " " + uV + ", interface preference " + d2s(iv[6 * nI + i], 2);
    print(msgI);
}

// ---- 6. tables ----
useReps = compare;
for (c = 0; c < nCond; c++) if (repCount(iRep, iCond, c) < 2) useReps = false;
unitName = "images"; if (useReps) unitName = "replicates";
graphed = newArray(0, 1, 2, 13, 9, 10); if (hasR) graphed = newArray(2, 3, 4, 5, 6, 7, 8);
summary = "Readout\tCondition\tMean\tSD\tn (" + unitName + ")";
if (compare) summary = summary + "\tRelative to " + condNames[0] + "\tChange vs " + condNames[0] + " (%)";
summary = summary + "\n";
graphs = newArray();
for (q = 0; q < nK; q++) {
    if (!hasR && q >= 3 && q <= 8) continue;
    v = Array.slice(iv, q * nI, (q + 1) * nI);
    gMean = newArray(nCond); gSd = newArray(nCond); px = newArray(); py = newArray();
    for (c = 0; c < nCond; c++) {
        pts = unitValues(v, iCond, iRep, c, useReps);
        gm = NaN; gs = NaN;
        if (pts.length > 0) Array.getStatistics(pts, mn, mx, gm, gs);
        if (pts.length < 2) gs = NaN;
        gMean[c] = gm; gSd[c] = gs;
        for (i = 0; i < pts.length; i++) { px = Array.concat(px, c + 0.25 * (i - (pts.length - 1) / 2) / maxOf(1, pts.length - 1)); py = Array.concat(py, pts[i]); }
        summary = summary + rNames[q] + "\t" + condNames[c] + "\t" + d2s(gm, 5) + "\t" + d2s(gs, 5) + "\t" + pts.length;
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
cellRows = "Condition\tReplicate\tFile\tSeries\tCell\tStatus\tTouches edge\tArea (um2)";
for (q = 0; q < nK; q++) if (hasR || q < 3 || q > 8) cellRows = cellRows + "\t" + rNames[q];
cellRows = cellRows + "\n";
for (k = 0; k < nC; k++) {
    i = cImg[k]; eTxt = "no"; if (cEdge[k]) eTxt = "yes";
    cellRows = cellRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + cLabel[k] + "\t" + cStatus[k] + "\t" + eTxt + "\t" + d2s(cArea[k], 2);
    for (q = 0; q < nK; q++) if (hasR || q < 3 || q > 8) cellRows = cellRows + "\t" + d2s(cVal[k * nK + q], 5);
    cellRows = cellRows + "\n";
}
imgRows = "Condition\tReplicate\tFile\tSeries\tCells measured\tCells excluded";
for (q = 0; q < nK; q++) if (hasR || q < 3 || q > 8) imgRows = imgRows + "\t" + rNames[q];
imgRows = imgRows + "\tPixel size (um)\tSlice step (um)\tSlices\n";
for (i = 0; i < nI; i++) {
    imgRows = imgRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + iCells[i] + "\t" + iOut[i];
    for (q = 0; q < nK; q++) if (hasR || q < 3 || q > 8) imgRows = imgRows + "\t" + d2s(iv[q * nI + i], 5);
    imgRows = imgRows + "\t" + d2s(iPx[i], 4) + "\t" + d2s(iDz[i], 3) + "\t" + iNz[i] + "\n";
}
repRows = "Condition\tReplicate\tImages\tCells measured";
qs = newArray(0, 1, 2); if (hasR) qs = newArray(0, 1, 2, 3, 4, 5, 6, 7, 8);
for (j = 0; j < qs.length; j++) repRows = repRows + "\t" + rNames[qs[j]];
repRows = repRows + "\n";
for (c = 0; c < nCond; c++) {
    reps = newArray();
    for (i = 0; i < nI; i++) if (iCond[i] == c) reps = Array.concat(reps, iRep[i]);
    reps = uniqueOf(reps);
    for (r = 0; r < reps.length; r++) {
        nn = 0; ncl = 0;
        for (i = 0; i < nI; i++) if (iCond[i] == c) { if (iRep[i] == reps[r]) { nn++; ncl += iCells[i]; } }
        repRows = repRows + condNames[c] + "\t" + reps[r] + "\t" + nn + "\t" + ncl;
        for (j = 0; j < qs.length; j++) { v = Array.slice(iv, qs[j] * nI, (qs[j] + 1) * nI); repRows = repRows + "\t" + d2s(repMean(v, iCond, iRep, c, reps[r]), 5); }
        repRows = repRows + "\n";
    }
}
// z sampling: contacts are small; slices further apart than ~0.3 um miss part of them in z
Array.getStatistics(iDz, dzMin, dzMax);
zNote = ""; if (!flat && dzMax > 0.3) zNote = "Slice step up to " + d2s(dzMax, 2) + " um: contacts thinner than that are partly missed in z (in-plane contacts are counted; across slices only within a slice).";
rPixTxt = "" + maxOf(0, round(dist / iPx[0])) + " pixel(s); 0 = the outlines overlap";
settings = "Setting\tValue\nPlugin\tConfocal Workflows " + pluginVersion() + "\nAnalysis\t" + mode + "\nMeasured on\t" + analysis + "\n";
if (flat) settings = settings + "2D warning\tin a max projection, structures at different depths land on the same pixels, so overlaps are inflated, more in thick cells or where organelles cluster, and differences between conditions can shrink or grow. Use 2D only for single planes or max projections, or to match earlier max-projection results; do not mix 2D and 3D numbers\n";
if (compare) for (g = 0; g < nCond; g++) settings = settings + condNames[g] + " folder\t" + dirs[g] + "\n";
else settings = settings + "Input\t" + fPath[0] + "\n";
settings = settings + "Organelle A (" + nameA + ")\t" + chA + "\nOrganelle B (" + nameB + ")\t" + chB + "\nContact reporter\t" + chR + "\nNuclei\t" + nucCh + "\nCells outlined with\t" + outlineCh
    + "\nCells\t"; if (whole) settings = settings + "whole field = one cell"; else settings = settings + "outline channel max projection, Gaussian 1 um, " + cellMethod + " threshold, holes filled; split halfway between nuclei (Voronoi; nuclei: " + nucMethod + " threshold); a cell needs >= " + minNuc + " um2 of its own nucleus; minimum " + minCell + " um2";
settings = settings + "\nTransfected cells\t" + nameA + " and " + nameB + " mean per voxel (background-subtracted) at least " + minLevel + " x the background noise (SD outside the cells); dimmer cells: listed, not measured"
    + "\nCell fragments\tcells with less " + nameA + " than " + minFrac + "% of the median cell (" + d2s(minFrac / 100 * medVA, 1) + " " + uV + "): listed, not measured"
    + "\nCells cut by the image edge\t"; if (excludeEdge) settings = settings + "excluded"; else settings = settings + "measured and flagged";
settings = settings
    + "\n" + nameA + " / " + nameB + " outlines\tevery slice: rolling ball " + radA + " / " + radB + " um, 1-pixel Gaussian, remaining background set to 0; thresholds " + d2s(thrA, 3) + " / " + d2s(thrB, 3) + " (Otsu, median of the " + condNames[0] + " stacks), applied to all images"
    + "\nApposition\t" + nameA + " voxels within " + d2s(dist, 3) + " um (" + rPixTxt + ", in the plane of each slice) of " + nameB + ", as a share of " + nameA + "; confocal resolution is far coarser than a contact, so this is apposition within the resolution limit, not contact"
    + "\nApposition at random\tshare of the cell's volume (outline channel, 3D Gaussian 1 um, Otsu) within the same distance of " + nameB + ": what " + nameA + " placed anywhere in the cell would get. Enrichment = measured / random (1 = no more than chance; crowded or swollen organelles raise both)";
if (hasR) settings = settings
    + "\nReporter puncta\tevery slice: rolling ball " + radR + " um, 1-pixel Gaussian; >= " + d2s(TR3, 3) + " (" + methodR + " on the " + condNames[0] + " max projections = " + d2s(TR, 3) + ", but at least 5x the single-slice noise)"
    + "\n" + nameR + "s\treporter puncta within the contact distance of both " + nameA + " and " + nameB + " (inside the cell); volume per cell and per " + nameA + " volume; puncta counted on the max projection"
    + "\n" + nameR + " enrichment\tshare of the cell's reporter puncta volume at " + nameA + "-" + nameB + " interfaces / share of the cell's volume that is interface: 1 = the reporter sits at interfaces no more than chance"
    + "\nInterface preference\treporter / " + nameA + " signal (both background-subtracted) on " + nameA + " within the distance of " + nameB + ", divided by the same away from it: 1 = the reporter follows " + nameA + " evenly (e.g. streptavidin binding the naturally biotinylated carboxylases inside mitochondria); above 1 = concentrated at the interface"
    + "\nShare of the reporter at " + nameR + "s\treporter in the " + nameR + " volume / reporter in the whole cell";
if (zNote != "") settings = settings + "\nZ sampling\t" + zNote;
settings = settings + "\nStatistics unit\t" + unitName + " (image value = mean of its measured cells)\nImages measured\t" + nI + "\n";
xlsx = outDir + "contacts_results.xlsx";
err = writeXlsx(xlsx, newArray("Summary", "Replicates", "Images", "Cells", "Settings"), newArray(summary, repRows, imgRows, cellRows, settings));
if (err != "") print("Excel file could not be written: " + err);
if (graphs.length > 0) {
    for (i = 0; i < graphs.length; i++) open(graphs[i]);
    run("Images to Stack", "method=[Copy (center)] name=graphs title=bar_ use");
    run("Make Montage...", "columns=" + minOf(4, graphs.length) + " rows=" + Math.ceil(graphs.length / 4) + " scale=1 border=0");
    saveAs("PNG", outDir + "bar_graphs.png");
    close("*");
    for (i = 0; i < graphs.length; i++) ok = File.delete(graphs[i]);
}

// ---- 7. zoomed 3D view of the contacts (optional): one image, a box you draw (or the whole image) ----
viewNote = "";
doView = false; vi = viewTest; if (vi >= 0) doView = true;
if (interactive) {
    choices = newArray(nI);
    for (i = 0; i < nI; i++) choices[i] = "" + (i + 1) + ": " + condNames[iCond[i]] + " / " + iFile[i];
    Dialog.create("Contacts: 3D view");
    Dialog.addMessage("Make a 3D surface view of " + nameA + " (green), " + nameB + " (red) and their contacts (white)?\n"
        + "You will draw a box on the image to zoom into; no box = the whole image (slower).");
    Dialog.addCheckbox("Make a 3D view", true);
    Dialog.addChoice("Image", choices, choices[0]);
    Dialog.show();
    doView = Dialog.getCheckbox(); pick = Dialog.getChoice(); vi = parseInt(substring(pick, 0, indexOf(pick, ":"))) - 1;
}
if (doView) {
    setBatchMode(true);
    chs = newArray(2); chs[0] = cA; chs[1] = cB; names = newArray("vA", "vB");
    if (hasR) { chs = Array.concat(chs, cR); names = Array.concat(names, "vR"); }
    err = loadChannels(iPath[vi], iSer[vi] - 1, chs, names);
    if (err != "") viewNote = "3D view: " + iFile[vi] + " " + err;
    else {
        selectWindow("vA"); getVoxelSize(pw, ph, pd, unit);
        projectTo("vA", "pA"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        projectTo("vB", "pB"); run("Enhance Contrast", "saturated=0.35"); run("8-bit");
        run("Merge Channels...", "c1=pB c2=pA create"); rename("pick");
        bx = 0; by = 0; bw = getWidth(); bh = getHeight();
        if (interactive) {
            setBatchMode("show"); setTool("rectangle");
            waitForUser("Contacts: 3D view", "Draw a box around the region to view in 3D (a few um across renders fastest),\nthen click OK. No box = the whole image.");
            selectWindow("pick"); if (selectionType() >= 0) getSelectionBounds(bx, by, bw, bh);
        } else { bx = round(bw / 4); by = round(bh / 4); bw = round(bw / 2); bh = round(bh / 2); }
        close("pick");
        // the same outlines as the measurement, cropped to the box
        rPix = maxOf(0, round(dist / pw));
        b = prepare("vA", radA); selectWindow("vA"); setThreshold(thrA, 1e30); run("Convert to Mask", "background=Dark black");
        b = prepare("vB", radB); selectWindow("vB"); setThreshold(thrB, 1e30); run("Convert to Mask", "background=Dark black");
        vlist = newArray("vA", "vB"); if (hasR) vlist = Array.concat(vlist, "vR");
        if (hasR) { b = prepare("vR", radR); selectWindow("vR"); setThreshold(TR3, 1e30); run("Convert to Mask", "background=Dark black"); }
        for (j = 0; j < vlist.length; j++) { selectWindow(vlist[j]); makeRectangle(bx, by, bw, bh); run("Crop"); setVoxelSize(pw, ph, pd, unit); }
        selectWindow("vB"); run("Duplicate...", "title=vdB duplicate"); if (rPix > 0) run("Maximum...", "radius=" + rPix + " stack");
        imageCalculator("AND create stack", "vA", "vdB"); rename("vC");          // A within the distance of B
        if (hasR) {                                                              // contacts = reporter there
            selectWindow("vA"); run("Duplicate...", "title=vdA duplicate"); if (rPix > 0) run("Maximum...", "radius=" + rPix + " stack");
            imageCalculator("AND create stack", "vR", "vdA"); rename("vRA"); imageCalculator("AND create stack", "vRA", "vdB"); rename("vM");
            close("vC"); selectWindow("vM"); rename("vC"); close("vRA"); close("vdA");
        }
        close("vdB");
        selectWindow("vC"); setVoxelSize(pw, ph, pd, unit);
        base = qcDir + qcBase(condNames[iCond[vi]], iRep[vi], iFile[vi], iSer[vi] - 1, 1) + "_3D";
        resample = maxOf(1, round(maxOf(bw, bh) / 300));
        setBatchMode("exit and display");
        r = surfaceView("vA", "vB", "vC", base + ".png", resample, interactive);
        if (r != "") {
            // no 3D graphics (e.g. a remote session): rotating projections of the three outlines instead
            print("3D Viewer unavailable (" + r + "); using 3D Project instead.");
            setBatchMode(true);
            r2 = projectView("vA", "vB", "vC", base + "_projection.png", pd);
            viewNote = "3D view (rotating projection; the 3D Viewer could not start here): " + base + "_projection.png";
        } else viewNote = "3D view: " + base + ".png" + "  (the 3D window stays open: drag to rotate, File > Take snapshot to save another view)";
        close("vA"); close("vB"); close("vC"); if (isOpen("vR")) close("vR");
    }
    setBatchMode(false);
}
setBatchMode(false);
total = 0; for (i = 0; i < nI; i++) total += iCells[i];
nDim = 0; for (k = 0; k < nC; k++) if (cStatus[k] == "too dim (untransfected)") nDim++;
done = "Measured " + total + " cells in " + nI + " images (" + nDim + " too dim to count as transfected).\n \nResults:  " + xlsx;
if (graphs.length > 0) done = done + "\nBar graphs:  " + outDir + "bar_graphs.png";
done = done + "\nQC images:  " + qcDir + "\n \nStatistics use " + unitName + ", not pooled cells.";
if (flat) done = done + "\n \n2D max projection: overlaps are inflated (structures at different depths overlap in the projection), more in thick cells or where organelles cluster. Do not compare these numbers with 3D results.";
else if (zNote != "") done = done + "\n \n" + zNote;
if (noBgList != "") done = done + "\n \nLittle cell-free background (under 2% of the field), so background and noise are less certain in:\n" + noBgList;
if (skipped != "") done = done + "\n \nNot processed:\n" + skipped + "A file listed here that should match the others is most likely damaged.";
if (viewNote != "") done = done + "\n \n" + viewNote;
if (graphs.length > 0 && interactive) open(outDir + "bar_graphs.png");
print("Done. " + done);
if (interactive) showMessage("Contacts finished", done);

// ================= functions (contacts) =================

// 2D mode: replace every open channel stack in names by its max projection (same title).
function flattenAll(names) {
    for (i = 0; i < names.length; i++) {
        if (!isOpen(names[i])) continue;
        selectWindow(names[i]);
        if (nSlices > 1) { run("Z Project...", "projection=[Max Intensity]"); t = getTitle(); close(names[i]); selectWindow(t); rename(names[i]); }
    }
}

// Sum over the slices of a 0/255 mask stack, as a 0..n count image (32-bit, 2D) named newTitle.
function sumMask(mask, newTitle) {
    selectWindow(mask); run("Duplicate...", "title=sm_tmp duplicate"); run("32-bit"); run("Divide...", "value=255 stack");
    sumOf("sm_tmp", newTitle); close("sm_tmp");
}

// Sum over the slices of an intensity stack inside a 0/255 mask stack (32-bit, 2D) named newTitle.
function sumWeighted(img, mask, newTitle) {
    selectWindow(mask); run("Duplicate...", "title=sw_m duplicate"); run("32-bit"); run("Divide...", "value=255 stack");
    imageCalculator("Multiply create 32-bit stack", img, "sw_m"); rename("sw_p");
    sumOf("sw_p", newTitle); close("sw_m"); close("sw_p");
}

// Surfaces of three 0/255 stacks (A green, B red see-through, C white solid) in the 3D Viewer; saves a snapshot to
// file. The window stays open when keep is true. Returns "" or the reason the 3D Viewer could not be used.
function surfaceView(a, b, c, file, resample, keep) {
    js = "var C3 = Packages.org.jogamp.vecmath.Color3f, W = Packages.ij.WindowManager, err = '';"
       + "try { var u = new Packages.ij3d.Image3DUniverse(800, 800); u.show();"
       + "  var ch = java.lang.reflect.Array.newInstance(java.lang.Boolean.TYPE, 3); ch[0] = true; ch[1] = true; ch[2] = true;"
       + "  var ca = u.addMesh(W.getImage('" + a + "'), new C3(0.2, 1, 0.2), 'A', 128, ch, " + resample + "); ca.setTransparency(0.6);"
       + "  var cb = u.addMesh(W.getImage('" + b + "'), new C3(1, 0.25, 0.25), 'B', 128, ch, " + resample + "); cb.setTransparency(0.75);"
       + "  var cc = u.addMesh(W.getImage('" + c + "'), new C3(1, 1, 1), 'contacts', 128, ch, 1);"
       + "  ca.showCoordinateSystem(false); cb.showCoordinateSystem(false); cc.showCoordinateSystem(false);"
       + "  java.lang.Thread.sleep(3000); u.resetView(); u.adjustView(); java.lang.Thread.sleep(500);"
       + "  u.rotateUniverse(new Packages.org.jogamp.vecmath.Vector3d(1, 0, 0), -0.5); u.fireTransformationUpdated(); java.lang.Thread.sleep(1500);"
       + "  var snap = u.takeSnapshot();"
       + "  if (snap == null) err = 'no snapshot'; else Packages.ij.IJ.saveAs(snap, 'png', '" + jsText(file) + "');"
       + "  if (!" + keep + ") u.close();"
       + "} catch (e) { err = String(e); } err;";
    return eval("js", js);
}

// Fallback without 3D graphics: the three outlines merged (A green, B red, contacts white) and rotated about the
// y axis with 3D Project, saved as a montage of 6 views to file.
function projectView(a, b, c, file, pd) {
    selectWindow(a); run("Duplicate...", "title=pa duplicate"); run("Divide...", "value=2 stack");
    selectWindow(b); run("Duplicate...", "title=pb duplicate"); run("Divide...", "value=2 stack");
    imageCalculator("Max stack", "pa", c); imageCalculator("Max stack", "pb", c);
    selectWindow(c); run("Duplicate...", "title=pc duplicate");
    run("Merge Channels...", "c1=pb c2=pa c3=pc create"); run("Stack to RGB", "slices keep"); rename("prgb"); close("Composite");
    getVoxelSize(pw, ph, pdd, unit);
    run("3D Project...", "projection=[Brightest Point] axis=Y-Axis slice=" + pd + " initial=0 total=300 rotation=60 lower=1 upper=255 opacity=0 surface=100 interior=50 interpolate");
    rename("prot3d");
    run("Make Montage...", "columns=3 rows=2 scale=1 border=4");
    saveAs("PNG", file); close(); close("prot3d"); close("prgb");
    return "";
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
function pluginVersion() { return "1.0.0"; }
