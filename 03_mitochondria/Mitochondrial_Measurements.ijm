// Mitochondria workflow: particle count and mitochondrial length (skeleton), in 2D and optionally in 3D.
//
//   1. Choose "Control vs treated" (pick the control folder, then one or more treated folders, e.g. doses) or
//      "Absolute" (one file or one folder; optionally outline regions or single cells on each image).
//      A folder can hold the images directly or one subfolder per replicate. Any Bio-Formats format.
//      Pick the channel that shows mitochondria (any marker or dye).
//   2. Each image is prepared for outlining: rolling-ball background subtraction (removes the cytoplasmic haze),
//      a 1-pixel Gaussian, and the remaining background (median of the pixels below Otsu) set to 0.
//      2D = this done on the max projection; 3D = on every slice of the stack.
//   3. Threshold: Otsu on the control images (all images in absolute mode) is the default; every other ImageJ
//      method is listed from low to high, in a live window with yellow outlines. For shape the threshold has to
//      separate neighbouring tubules (too low merges them into blobs, too high breaks them into dots). The chosen
//      value is applied UNCHANGED to every image. 3D uses the same value, but never less than 5x the noise of
//      single slices (noisier than the projection), so slice noise does not become fake branches.
//   4. Holes up to 0.5 um2 in the outlines are filled: outer-membrane markers (TOM20, TOM70 ...) show swollen
//      mitochondria as rings, whose skeleton would otherwise be a loop around the lumen.
//   5. Readouts per image (or per outlined region):
//        length per piece     total skeleton length / number of pieces (headline; the mean length of a
//                             mitochondrion or connected network, per cell when a field or region is one cell)
//        mean branch length   total skeleton length / branches (segments between junctions and ends)
//        pieces, mean area and perimeter per piece (2D), mean volume per piece (3D), totals, branches, junctions
//      Per piece (Pieces sheet): branches, junctions, length, longest path and whether it touches the image or
//      region edge (a cut piece's length is wrong).
//   6. 3D (optional, z-stacks): the same measurements on the full stack, side by side with 2D, with 3D/2D ratios.
//      A max projection merges mitochondria that overlap in z. The z-step is checked: above 3x the pixel size the
//      3D skeleton is unreliable; this is a warning only (noted in Settings and in the Images sheet).
//   7. Writes mitochondria_results.xlsx (Summary relative to control, Replicates, Images, Pieces, Threshold
//      methods, Settings), bar graphs, and qc/ images (outlines yellow, skeleton magenta, regions cyan; 3D views at
//      0, 45, 90 and 135 degrees around the vertical axis).
//      Statistics use replicate means when every condition has >= 2 replicate subfolders, otherwise images
//      (or regions); never pooled pieces.

// ---- settings ----
interactive = true;          // false = use the defaults below without dialogs (testing)
// ------------------

requires("1.54");
setOption("BlackBackground", true);

// ---- 1. what to measure ----
modes = newArray("Control vs treated (one or more treated folders, e.g. doses)", "Absolute (no comparison)");
inputs = newArray("A folder", "One file");
mode = modes[0]; input = inputs[0]; useRois = false;
if (interactive) {
    Dialog.create("Mitochondria");
    Dialog.addRadioButtonGroup("Analysis", modes, 2, 1, mode);
    Dialog.addMessage("Control vs treated: you will pick the control folder, then a treated folder; you can then add\n"
        + "more treated folders (other doses or drugs). All share the control's threshold and one graph.\n"
        + "Absolute: measure one file or one folder on its own, optionally in regions or cells you outline.\n"
        + "A folder can hold the images directly or one subfolder per replicate. Use raw or deconvolved stacks.");
    Dialog.show();
    mode = Dialog.getRadioButton();
    if (mode == modes[1]) {
        Dialog.create("Mitochondria: absolute");
        Dialog.addRadioButtonGroup("Measure", inputs, 1, 2, input);
        Dialog.addCheckbox("Outline regions or cells on each image (otherwise the whole field)", useRois);
        Dialog.show();
        input = Dialog.getRadioButton(); useRois = Dialog.getCheckbox();
    }
}
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
chNames = newArray(); anyZ = false;
for (i = 0; i < lines.length; i++) {
    f = split(lines[i], "\t");
    if (f[0] == "S") { if (parseInt(f[4]) > 1) anyZ = true; }
    if (f[0] == "C") { if (parseInt(f[1]) == 0) chNames = Array.concat(chNames, "C" + (parseInt(f[2]) + 1) + " " + f[3]); }
}
measureCh = chNames[0];
analyses = newArray("2D (max projection)", "2D + 3D (full stack)");
analysis = analyses[0];
bgRadius = 1;          // um, rolling-ball radius
minArea = 0.1;         // um^2; 3D uses the same number of voxels as this area in pixels
lumenMax = 0.5;        // um^2; holes up to this size are filled (0 = off)
if (interactive) {
    Dialog.create("Mitochondria: options");
    if (compare) {
        for (g = 0; g < nCond; g++) {
            nf = countOf(fCond, g);
            label = "Control name"; if (g > 0) label = "Treated " + g + " name";
            Dialog.addString(label, condNames[g], 20);
            Dialog.addToSameRow(); Dialog.addMessage("(" + nf + " files)");
        }
    } else Dialog.addMessage("" + fPath.length + " file(s)");
    Dialog.addChoice("Mitochondria channel", chNames, measureCh);
    if (anyZ) Dialog.addRadioButtonGroup("Analysis", analyses, 1, 2, analysis);
    Dialog.addNumber("Background radius", bgRadius, 1, 6, "um (larger than a mitochondrion's width)");
    Dialog.addNumber("Minimum object size", minArea, 2, 6, "um2 (smaller pieces ignored)");
    Dialog.addNumber("Fill holes up to", lumenMax, 2, 6, "um2 (0 = off)");
    Dialog.addMessage("Outer-membrane markers (TOM20, TOM70 ...) show swollen mitochondria as rings; filling the\n"
        + "small lumen keeps a ring from being measured as a long loop. Gaps in a network are larger and stay open.");
    Dialog.show();
    if (compare) for (g = 0; g < nCond; g++) condNames[g] = Dialog.getString();
    measureCh = Dialog.getChoice();
    if (anyZ) analysis = Dialog.getRadioButton();
    bgRadius = Dialog.getNumber(); minArea = Dialog.getNumber(); lumenMax = Dialog.getNumber();
}
do3D = false; if (analysis == analyses[1]) do3D = true;
for (c = 0; c < nCond; c++) condNames[c] = replace(condNames[c], "[,{}|'\t]", " ");
ch = parseInt(substring(measureCh, 1, indexOf(measureCh, " ")));
qcDir = outDir + "qc" + File.separator;
File.makeDirectory(qcDir);
setBatchMode(true);
skipped = "";

// ---- 3. threshold: score every method on the prepared projections of the reference images ----
methods = getList("threshold.methods");
nM = methods.length; NB = 1024;
refT = newArray(); hv = newArray(); hc = newArray(); nRef = 0; nPrev = 0; maxV = 0; sliceNoise = newArray();
for (fi = 0; fi < fPath.length; fi++) {
    if (fCond[fi] != 0) continue;
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (s == -1) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
        one = newArray(1); one[0] = ch; err = loadChannels(fPath[fi], s, one, newArray("raw"));
        if (err != "") { skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        projectTo("raw", "p2");
        bg = prepare("p2", bgRadius);
        selectWindow("raw");
        if (do3D && nSlices > 1) {
            bg3 = prepare("raw", bgRadius);
            n3r = noiseRms("raw");
            sliceNoise = Array.concat(sliceNoise, n3r);
        }
        close("raw");
        selectWindow("p2");
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
        if (nPrev < 6) { nPrev++; rename("ref" + nPrev); } else close("p2");
    }
}
if (nRef == 0) exit("None of the " + condNames[0] + " images could be read.\n" + skipped);
// 3D uses the same threshold, but never less than 5x the noise of single slices (they are noisier than the
// projection, so a value just above the projection's noise would turn slice noise into fake branches).
noise3 = 0;
if (sliceNoise.length > 0) noise3 = medianOf(sliceNoise);
// For shape, the threshold has to separate neighbouring tubules rather than capture all the light, so Otsu (the
// usual choice in mitochondria tools) is the default; the other methods are listed by value for comparison.
mT = newArray(nM); mPct = newArray(nM); otsu = 0;
for (m = 0; m < nM; m++) {
    t = newArray(nRef);
    for (r = 0; r < nRef; r++) t[r] = refT[r * nM + m];
    mT[m] = medianOf(t);
    for (r = 0; r < nRef; r++) { st = scoreThreshold(hv, hc, r * NB, NB, mT[m]); mPct[m] += st[1] / nRef; }
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
    msg = "Every threshold method was tried on " + nRef + " " + condNames[0] + " image(s) (prepared max projections).\n"
        + "Default: Otsu. Other methods are listed from low to high. Too low a value merges neighbouring tubules\n"
        + "into blobs; too high a value breaks them into dots.\n"
        + "Yellow outlines = what will count as mitochondria: they should follow the mitochondria, not the haze.\n"
        + "Type a value, move the slider or pick a method; scroll the image to check the other images.\n"
        + "This one value is applied to every image.";
    if (do3D) msg = msg + "\n3D uses the same value, but at least " + d2s(5 * noise3, 1) + " (5x the noise of single slices).";
    r = thresholdDialog("Mitochondria: threshold", msg, labels, ordT, maxV);
    if (r == "cancel") exit;
    if (startsWith(r, "ERR")) exit("Threshold window failed: " + r);
    f = split(r, "\t"); T = parseFloat(f[0]); method = methods[order[parseInt(f[1])]];
    if (f[2] == "1") method = method + " (edited)";
}
close("preview");
T3 = maxOf(T, 5 * noise3);
print("Fixed threshold: " + T + " (" + method + ", from " + nRef + " images)");
if (do3D) print("3D threshold: " + T3 + " (slice noise " + noise3 + ")");
methodRows = "Method\tThreshold (prepared image)\tOutlined area (%)\n";
for (k = 0; k < nM; k++) { m = order[k]; methodRows = methodRows + methods[m] + "\t" + d2s(mT[m], 3) + "\t" + d2s(mPct[m], 3) + "\n"; }

// ---- 4. measure every image (every outlined region) ----
pieceRows = "Condition\tReplicate\tFile\tSeries\tRegion\tAnalysis\tPiece\tBranches\tJunctions\tLength (um)\tLongest path (um)\tTouches edge\n";
iCond = newArray(); iRep = newArray(); iFile = newArray(); iSer = newArray(); iReg = newArray();
iN2 = newArray(); iArea2 = newArray(); iLpp2 = newArray(); iMa2 = newArray(); iMp2 = newArray(); iLpp3 = newArray(); iMv3 = newArray(); iLen2 = newArray(); iBr2 = newArray(); iJn2 = newArray(); iMbl2 = newArray();
iN3 = newArray(); iVol3 = newArray(); iLen3 = newArray(); iBr3 = newArray(); iJn3 = newArray(); iMbl3 = newArray();
iDz = newArray(); iZok = newArray();
coarseList = "";
for (fi = 0; fi < fPath.length; fi++) {
    use = usableSeries(fPath[fi]);
    for (u = 0; u < use.length; u++) {
        s = use[u];
        if (s < 0) { if (s == -1 && fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + " is damaged (could not be read)\n"; continue; }
        one = newArray(1); one[0] = ch; err = loadChannels(fPath[fi], s, one, newArray("raw"));
        if (err != "") { if (fCond[fi] != 0) skipped = skipped + File.getName(fPath[fi]) + ": " + err + "\n"; continue; }
        name = File.getName(fPath[fi]);
        cname = condNames[fCond[fi]];
        qb = qcBase(cname, fRep[fi], name, s, use.length);
        selectWindow("raw");
        getVoxelSize(pw, ph, pd, unit);
        nz = nSlices;
        projectTo("raw", "mip");
        projectTo("raw", "p2");
        bg2 = prepare("p2", bgRadius);
        has3D = false; if (do3D && nz > 1) has3D = true;
        if (has3D) {
            bg3 = prepare("raw", bgRadius);
            coarse = false; if (pd > 3 * pw) coarse = true;
            if (coarse) coarseList = coarseList + name + " (z-step " + d2s(pd, 2) + " " + unit + ")\n";
        }
        // regions: whole field, or the ones outlined by the user
        roiManager("reset");
        if (useRois) {
            selectWindow("mip");
            if (interactive) {
                run("Duplicate...", "title=[" + name + " - outline regions]");
                run("Enhance Contrast", "saturated=0.35");
                setBatchMode("show");
                waitForUser("Outline regions", "Outline a region or cell in " + name + " with any selection tool and press T to add it\n"
                    + "to the ROI Manager. Repeat for each region, then click OK.\nNo regions = the whole field is measured.");
                close(name + " - outline regions");
            }
        }
        nReg = roiManager("count");
        if (nReg == 0) nReg = 1;
        for (rg = 0; rg < nReg; rg++) {
            regName = "field";
            if (roiManager("count") > 0) regName = "region " + (rg + 1);
            // ---- 2D ----
            maskFrom("p2", T, "m2", rg);
            fillSmallHoles("m2", lumenMax);
            selectWindow("m2");
            run("Set Measurements...", "area perimeter redirect=None decimal=4");
            run("Analyze Particles...", "size=" + minArea + "-Infinity show=Masks display clear");
            rename("m2f");
            n2 = nResults; area2 = 0; perim2 = 0;
            for (r = 0; r < n2; r++) { area2 += getResult("Area", r); perim2 += getResult("Perim.", r); }
            run("Clear Results");
            close("m2");
            selectWindow("m2f");
            run("Duplicate...", "title=sk2");
            run("Skeletonize (2D/3D)");
            st = skeletonSummary("sk2", rg, cname, fRep[fi], name, s + 1, regName, "2D");
            pieceRows = pieceRows + st[0];
            iCond = Array.concat(iCond, fCond[fi]); iRep = Array.concat(iRep, fRep[fi]); iFile = Array.concat(iFile, name);
            iSer = Array.concat(iSer, s + 1); iReg = Array.concat(iReg, regName);
            iN2 = Array.concat(iN2, n2); iArea2 = Array.concat(iArea2, area2);
            lpp = NaN; ma = NaN; mp = NaN; if (n2 > 0) { lpp = st[1] / n2; ma = area2 / n2; mp = perim2 / n2; }
            iLpp2 = Array.concat(iLpp2, lpp); iMa2 = Array.concat(iMa2, ma); iMp2 = Array.concat(iMp2, mp);
            iLen2 = Array.concat(iLen2, st[1]); iBr2 = Array.concat(iBr2, st[2]); iJn2 = Array.concat(iJn2, st[3]); iMbl2 = Array.concat(iMbl2, st[4]);
            // QC: the outlines and skeleton of this region
            if (rg == 0) { selectWindow("mip"); run("Duplicate...", "title=qc"); run("Enhance Contrast", "saturated=0.35"); run("8-bit"); run("RGB Color"); }
            drawOutline("qc", "m2f", 255, 220, 0, false);
            drawOutline("qc", "sk2", 255, 0, 255, true);
            if (roiManager("count") > 0) { selectWindow("qc"); roiManager("select", rg); setForegroundColor(0, 220, 255); run("Draw", "slice"); run("Select None"); }
            close("m2f"); close("sk2");
            // ---- 3D ----
            n3 = NaN; vol3 = NaN; l3 = NaN; b3 = NaN; j3 = NaN; mb3 = NaN;
            if (has3D) {
                maskFrom("raw", T3, "m3", rg);
                fillSmallHoles("m3", lumenMax);
                selectWindow("m3");
                minVox = maxOf(1, round(minArea / (pw * ph)));
                run("Clear Results");
                run("3D OC Options", "volume nb_of_obj._voxels dots_size=5 font_size=10 redirect_to=none");
                run("3D Objects Counter", "threshold=128 slice=1 min.=" + minVox + " max=999999999 statistics");
                n3 = nResults; vol3 = 0;
                head = split(String.getResultsHeadings, "\t"); volCol = "";
                for (h = 0; h < head.length; h++) if (startsWith(head[h], "Volume")) volCol = head[h];
                for (r = 0; r < n3; r++) vol3 += getResult(volCol, r);
                print("   3D objects: " + n3 + ", volume " + d2s(vol3, 2));
                run("Clear Results");
                if (rg == 0) { v3 = qcDir + qb + "_3D.png"; view3D("m3", "raw", pd, v3); }
                selectWindow("m3");
                run("Skeletonize (2D/3D)");
                st = skeletonSummary("m3", rg, cname, fRep[fi], name, s + 1, regName, "3D");
                pieceRows = pieceRows + st[0];
                l3 = st[1]; b3 = st[2]; j3 = st[3]; mb3 = st[4];
                close("m3");
            }
            iN3 = Array.concat(iN3, n3); iVol3 = Array.concat(iVol3, vol3); iLen3 = Array.concat(iLen3, l3);
            lpp = NaN; mv = NaN; if (n3 > 0) { lpp = l3 / n3; mv = vol3 / n3; }
            iLpp3 = Array.concat(iLpp3, lpp); iMv3 = Array.concat(iMv3, mv);
            iBr3 = Array.concat(iBr3, b3); iJn3 = Array.concat(iJn3, j3); iMbl3 = Array.concat(iMbl3, mb3);
            zs = "-"; if (has3D) { zs = "OK"; if (coarse) zs = "coarse"; }
            iDz = Array.concat(iDz, pd); iZok = Array.concat(iZok, zs);
            k2 = iCond.length - 1;
            print(cname + " / " + name + " " + regName + ": 2D " + n2 + " pieces, length per piece " + d2s(iLpp2[k2], 3) + ", mean branch " + d2s(iMbl2[k2], 3)
                + "; 3D length per piece " + d2s(iLpp3[k2], 3) + ", mean branch " + d2s(iMbl3[k2], 3) + " " + unit);
        }
        selectWindow("qc");
        saveAs("PNG", qcDir + qb + "_qc.png");
        close("*");
        roiManager("reset");
    }
}
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }
if (iCond.length == 0) exit("No image could be measured.\n" + skipped);
if (coarseList != "") {
    msgZ = "These stacks have a z-step more than 3x the pixel size; their 3D lengths and counts are less reliable\n"
        + "(0.2-0.25 um steps are recommended at 60x/100x). Results are still reported:\n" + coarseList;
    print(msgZ);
}

// ---- 5. tables ----
regionUnit = "images"; if (useRois) regionUnit = "regions";
useReps = compare;
for (c = 0; c < nCond; c++) if (repCount(iRep, iCond, c) < 2) useReps = false;
unitName = regionUnit; if (useReps) unitName = "replicates";
readouts = newArray("Length per piece 2D (um)", "Mean branch length 2D (um)", "Pieces 2D", "Mean area per piece 2D (um2)",
    "Mean perimeter per piece 2D (um)", "Total skeleton length 2D (um)", "Total area 2D (um2)");
if (do3D) readouts = Array.concat(readouts, newArray("Length per piece 3D (um)", "Mean branch length 3D (um)", "Pieces 3D",
    "Mean volume per piece 3D (um3)", "Total skeleton length 3D (um)", "Total volume 3D (um3)"));
graphed = newArray(0, 1, 2, 7, 8, 9);     // the headline readouts get bar graphs
summary = "Readout\tCondition\tMean\tSD\tn (" + unitName + ")";
if (compare) summary = summary + "\tRelative to " + condNames[0] + "\tChange vs " + condNames[0] + " (%)";
summary = summary + "\n";
graphs = newArray();
for (k = 0; k < readouts.length; k++) {
    if (k == 0) v = iLpp2; if (k == 1) v = iMbl2; if (k == 2) v = iN2; if (k == 3) v = iMa2; if (k == 4) v = iMp2; if (k == 5) v = iLen2; if (k == 6) v = iArea2;
    if (k == 7) v = iLpp3; if (k == 8) v = iMbl3; if (k == 9) v = iN3; if (k == 10) v = iMv3; if (k == 11) v = iLen3; if (k == 12) v = iVol3;
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
imgRows = "Condition\tReplicate\tFile\tSeries\tRegion\tPieces 2D\tLength per piece 2D (um)\tMean branch length 2D (um)\tMean area per piece 2D (um2)"
    + "\tMean perimeter per piece 2D (um)\tTotal skeleton length 2D (um)\tTotal area 2D (um2)\tBranches 2D\tJunctions 2D";
if (do3D) imgRows = imgRows + "\tPieces 3D\tLength per piece 3D (um)\tMean branch length 3D (um)\tMean volume per piece 3D (um3)\tTotal skeleton length 3D (um)"
    + "\tTotal volume 3D (um3)\tBranches 3D\tJunctions 3D\tPieces 3D/2D\tLength per piece 3D/2D\tMean branch length 3D/2D\tz-step (um)\tz-sampling";
imgRows = imgRows + "\n";
for (i = 0; i < iCond.length; i++) {
    imgRows = imgRows + condNames[iCond[i]] + "\t" + iRep[i] + "\t" + iFile[i] + "\t" + iSer[i] + "\t" + iReg[i] + "\t" + iN2[i] + "\t" + d2s(iLpp2[i], 4)
        + "\t" + d2s(iMbl2[i], 4) + "\t" + d2s(iMa2[i], 4) + "\t" + d2s(iMp2[i], 4) + "\t" + d2s(iLen2[i], 4) + "\t" + d2s(iArea2[i], 4) + "\t" + iBr2[i] + "\t" + iJn2[i];
    if (do3D) imgRows = imgRows + "\t" + d2s(iN3[i], 0) + "\t" + d2s(iLpp3[i], 4) + "\t" + d2s(iMbl3[i], 4) + "\t" + d2s(iMv3[i], 4) + "\t" + d2s(iLen3[i], 4)
        + "\t" + d2s(iVol3[i], 4) + "\t" + d2s(iBr3[i], 0) + "\t" + d2s(iJn3[i], 0) + "\t" + d2s(iN3[i] / iN2[i], 4) + "\t" + d2s(iLpp3[i] / iLpp2[i], 4)
        + "\t" + d2s(iMbl3[i] / iMbl2[i], 4) + "\t" + d2s(iDz[i], 4) + "\t" + iZok[i];
    imgRows = imgRows + "\n";
}
repRows = "Condition\tReplicate\t" + regionUnit + "\tLength per piece 2D (um)\tMean branch length 2D (um)\tPieces 2D";
if (do3D) repRows = repRows + "\tLength per piece 3D (um)\tMean branch length 3D (um)\tPieces 3D";
repRows = repRows + "\n";
for (c = 0; c < nCond; c++) {
    reps = newArray();
    for (i = 0; i < iCond.length; i++) if (iCond[i] == c) reps = Array.concat(reps, iRep[i]);
    reps = uniqueOf(reps);
    for (r = 0; r < reps.length; r++) {
        nn = 0;
        for (i = 0; i < iCond.length; i++) if (iCond[i] == c) { if (iRep[i] == reps[r]) nn++; }
        repRows = repRows + condNames[c] + "\t" + reps[r] + "\t" + nn + "\t" + d2s(repMean(iLpp2, iCond, iRep, c, reps[r]), 4) + "\t" + d2s(repMean(iMbl2, iCond, iRep, c, reps[r]), 4) + "\t" + d2s(repMean(iN2, iCond, iRep, c, reps[r]), 3);
        if (do3D) repRows = repRows + "\t" + d2s(repMean(iLpp3, iCond, iRep, c, reps[r]), 4) + "\t" + d2s(repMean(iMbl3, iCond, iRep, c, reps[r]), 4) + "\t" + d2s(repMean(iN3, iCond, iRep, c, reps[r]), 3);
        repRows = repRows + "\n";
    }
}
settings = "Setting\tValue\nPlugin\tConfocal Workflows " + pluginVersion() + "\nAnalysis\t" + mode + "; " + analysis + "\n";
if (compare) for (g = 0; g < nCond; g++) settings = settings + condNames[g] + " folder\t" + dirs[g] + "\n";
else settings = settings + "Input\t" + fPath[0] + "\n";
if (useRois) settings = settings + "Regions\toutlined by hand on each image (Region column)\n";
settings = settings + "Mitochondria channel\t" + measureCh
    + "\nPreparation for outlining\trolling-ball background subtraction (radius " + bgRadius + " um), 1-pixel Gaussian, remaining background (median below Otsu) set to 0; 2D on the max projection, 3D on every slice"
    + "\nThreshold\t" + T + " (" + method + "; methods scored on " + nRef + " " + condNames[0] + " image(s), applied unchanged to all)";
if (do3D) settings = settings + "\n3D threshold\t" + T3 + " (the 2D threshold, but at least 5x the noise of single slices = " + d2s(5 * noise3, 3) + "; noise = RMS of the negative pixels after background subtraction, median over the scored stacks)";
settings = settings
    + "\nHoles filled\tup to " + lumenMax + " um2 (ring lumens of swollen mitochondria with outer-membrane markers; 0 = off)"
    + "\nMinimum object size\t" + minArea + " um2 (2D); the same number of voxels in 3D"
    + "\nPieces\t2D: Analyze Particles on the outline mask; 3D: 3D Objects Counter"
    + "\nSkeleton\tSkeletonize (2D/3D) + Analyze Skeleton (2D/3D), no pruning; mean branch length = total skeleton length / branches"
    + "\nTouches edge\ta piece with a skeleton point within 2 pixels of the image or region edge (its length is cut)";
if (do3D) settings = settings + "\nz-sampling\tcoarse = z-step > 3x pixel size (3D results still reported)";
settings = settings + "\nStatistics unit\t" + unitName + "\nImages measured\t" + iCond.length + "\n";
xlsx = outDir + "mitochondria_results.xlsx";
err = writeXlsx(xlsx, newArray("Summary", "Replicates", "Images", "Pieces", "Threshold methods", "Settings"),
    newArray(summary, repRows, imgRows, pieceRows, methodRows, settings));
if (err != "") print("Excel file could not be written: " + err);
if (graphs.length > 0) {
    for (i = 0; i < graphs.length; i++) open(graphs[i]);
    run("Images to Stack", "method=[Copy (center)] name=graphs title=bar_ use");
    run("Make Montage...", "columns=3 rows=" + Math.ceil(graphs.length / 3) + " scale=1 border=0");
    saveAs("PNG", outDir + "bar_graphs.png");
    close("*");
    for (i = 0; i < graphs.length; i++) ok = File.delete(graphs[i]);
}
setBatchMode(false);
done = "Measured " + iCond.length + " " + regionUnit + "; threshold " + d2s(T, 2) + " (" + method + ").\n \nResults:  " + xlsx;
if (graphs.length > 0) done = done + "\nBar graphs:  " + outDir + "bar_graphs.png";
done = done + "\nQC images:  " + qcDir + "\n \nStatistics use " + unitName + ", not pooled pieces.";
if (coarseList != "") done = done + "\n \nCoarse z-sampling (3D less reliable):\n" + coarseList;
if (skipped != "") done = done + "\n \nNot processed:\n" + skipped + "A file listed here that should match the others is most likely damaged.";
if (graphs.length > 0 && interactive) open(outDir + "bar_graphs.png");
print("Done. " + done);
if (interactive) showMessage("Mitochondria finished", done);

// ================= functions =================


// Fills holes (background regions not touching the image edge) of up to maxArea um^2 in the binary image or
// stack title (per slice); 0 = off.
function fillSmallHoles(title, maxArea) {
    if (maxArea <= 0) return;
    selectWindow(title);
    flag = ""; dup = ""; if (nSlices > 1) { flag = " stack"; dup = " duplicate"; }
    run("Duplicate...", "title=holes_inv" + dup);
    run("Invert", flag);
    run("Analyze Particles...", "size=0-" + maxArea + " exclude show=Masks clear" + flag);
    rename("holes_found");
    imageCalculator("OR" + flag, title, "holes_found");
    close("holes_found"); close("holes_inv");
    run("Clear Results");
}

// Binary mask newTitle of title >= T (all slices); outside ROI-Manager region rg cleared when regions exist.
function maskFrom(title, T, newTitle, rg) {
    selectWindow(title);
    flag = ""; if (nSlices > 1) flag = " duplicate";
    run("Duplicate...", "title=" + newTitle + flag);
    setThreshold(T, 1e30);
    run("Convert to Mask", "background=Dark black");
    if (roiManager("count") > 0) {
        roiManager("select", rg);
        setBackgroundColor(0, 0, 0);
        if (nSlices > 1) run("Clear Outside", "stack"); else run("Clear Outside");
        run("Select None");
    }
}

// Skeleton statistics of the skeleton image title, through Analyze Skeleton's API (works in batch mode).
// Returns [piece rows (tab-separated, with the given labels), total length, branches, junctions, mean branch length].
// A piece touches the edge when a skeleton point is within 2 pixels of the image edge or of region rg.
function skeletonSummary(title, rg, cond, rep, file, series, region, dim) {
    selectWindow(title);
    if (roiManager("count") > 0) { roiManager("select", rg); run("Enlarge...", "enlarge=-2 pixel"); }
    js = "var imp = Packages.ij.WindowManager.getImage('" + title + "'); var roi = imp.getRoi(); imp.deleteRoi();"
       + "var A = Packages.sc.fiji.analyzeSkeleton.AnalyzeSkeleton_; var as = new A(); as.setup('', imp);"
       + "var r = as.run(A.NONE, false, true, null, true, false);"
       + "var nb = r.getBranches(), nj = r.getJunctions(), av = r.getAverageBranchLength(), sp = r.getShortestPathList(), g = r.getGraph();"
       + "var W = imp.getWidth(), H = imp.getHeight(), out = [];"
       + "for (var i = 0; i < r.getNumOfTrees(); i++) { if (nb[i] < 1) continue; var edge = 0; var vs = g[i].getVertices();"
       + "  for (var k = 0; k < vs.size() && !edge; k++) { var ps = vs.get(k).getPoints(); for (var q = 0; q < ps.size(); q++) { var p = ps.get(q);"
       + "    if (p.x <= 1 || p.y <= 1 || p.x >= W - 2 || p.y >= H - 2 || (roi != null && !roi.contains(p.x, p.y))) { edge = 1; break; } } }"
       + "  out.push([nb[i], nj[i], nb[i] * av[i], sp.get(i), edge].join(',')); } out.join(';');";
    res = eval("js", js);
    rows = ""; totL = 0; totB = 0; totJ = 0; k = 0;
    if (res != "") {
        p = split(res, ";");
        for (i = 0; i < p.length; i++) {
            f = split(p[i], ",");
            b = parseInt(f[0]); j = parseInt(f[1]); L = parseFloat(f[2]); lsp = parseFloat(f[3]);
            edge = "no"; if (f[4] == "1") edge = "yes";
            totL += L; totB += b; totJ += j; k++;
            rows = rows + cond + "\t" + rep + "\t" + file + "\t" + series + "\t" + region + "\t" + dim + "\t" + k + "\t" + b + "\t" + j
                + "\t" + d2s(L, 4) + "\t" + d2s(lsp, 4) + "\t" + edge + "\n";
        }
    }
    mbl = NaN; if (totB > 0) mbl = totL / totB;
    out = newArray(5);
    out[0] = rows; out[1] = totL; out[2] = totB; out[3] = totJ; out[4] = mbl;
    return out;
}

// A 3D view of the mitochondria: the prepared fluorescence inside the 3D outlines, projected (brightest point)
// from 4 angles around the vertical axis, cropped to the structures (specks under 1 um2 ignored), saved as one PNG.
function view3D(mask, intensity, pd, file) {
    selectWindow(mask);
    run("Z Project...", "projection=[Max Intensity]");
    rename("v3proj");
    run("Analyze Particles...", "size=1-Infinity show=Masks clear");
    rename("v3big");
    setThreshold(255, 255);
    run("Create Selection");
    W = getWidth(); H = getHeight();
    bx = 0; by = 0; bw = W; bh = H;
    if (selectionType() >= 0) getSelectionBounds(bx, by, bw, bh);
    close("v3big"); close("v3proj");
    m = 20;
    bx = maxOf(0, bx - m); by = maxOf(0, by - m); bw = minOf(W - bx, bw + 2 * m); bh = minOf(H - by, bh + 2 * m);
    selectWindow(mask); makeRectangle(bx, by, bw, bh); run("Duplicate...", "title=v3m duplicate"); selectWindow(mask); run("Select None");
    selectWindow(intensity); makeRectangle(bx, by, bw, bh); run("Duplicate...", "title=v3i duplicate"); selectWindow(intensity); run("Select None");
    selectWindow("v3m"); run("32-bit"); run("Divide...", "value=255 stack");
    imageCalculator("Multiply create 32-bit stack", "v3i", "v3m");
    rename("v3in");
    run("3D Project...", "projection=[Brightest Point] axis=Y-Axis slice=" + pd + " initial=0 total=135 rotation=45 lower=0 upper=1e30 opacity=0 surface=100 interior=50 interpolate");
    rename("proj3d");
    run("Enhance Contrast", "saturated=0.5 process_all use");
    run("8-bit");
    run("Make Montage...", "columns=4 rows=1 scale=1 border=4");
    saveAs("PNG", file);
    close();
    close("proj3d"); close("v3in"); close("v3m"); close("v3i");
}


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

// Plugin version: shown by About and written into every results file.
function pluginVersion() { return "1.0.0"; }
