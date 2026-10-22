# Installing Confocal Workflows

You need Fiji (download it from https://fiji.sc). It runs on Windows, macOS and Linux and brings its own Java. The workflows need ImageJ 1.54 or newer, which any recent Fiji has; if a workflow says it needs a newer version, run Help › Update… first.

## Option 1: the update site (recommended)

Fiji then installs the workflows for you and brings in every fix when you update.

1. Start Fiji and open **Help › Update…**. Wait until it has checked for updates.
2. Click **Manage update sites**.
3. Click **Add Unlisted Site**. A new row appears at the bottom of the list.
4. In that row, set the name to `Confocal-Workflows` and the URL to `https://sites.imagej.net/Confocal-Workflows/`, and tick its box.
5. Click **Apply and Close**, then **Apply changes**.
6. Restart Fiji.

The workflows are now under **Plugins › Confocal Workflows**.

To get fixes later, run Help › Update… now and then; Fiji downloads the new version of the workflows along with its own updates.

## Option 2: the jar file

Use this if you cannot use the updater, for example on a computer without internet access.

1. Download [`Confocal_Workflows.jar`](Confocal_Workflows.jar) from this repository (the download button is on that page).
2. Drag the file onto the Fiji window and confirm, or copy it into the `plugins` folder inside your Fiji folder (`Fiji.app/plugins/`).
3. Restart Fiji.

To update, download the new jar and replace the old one in `plugins`. Fiji does not update a jar installed this way.

## Check that it worked

Open **Plugins › Confocal Workflows › About Confocal Workflows**. It shows the version you have. Every results workbook also records the version in its Settings sheet, so you can always tell which version produced a set of numbers.

## Uninstalling

- **Update site:** Help › Update… › Manage update sites, untick Confocal-Workflows, Apply and Close, Apply changes, restart.
- **Jar:** delete `Confocal_Workflows.jar` from `Fiji.app/plugins/` and restart.

## Problems

**The menu is missing.** Restart Fiji after installing. With the jar, check that it sits directly in `Fiji.app/plugins/`, not in a subfolder of your Downloads.

**Every workflow is listed twice.** You have both the jar and older loose `.ijm` copies of the workflows (or the jar twice). Delete the folder `Fiji.app/plugins/Confocal_Workflows/` if it exists, keep one copy of the jar, and restart.

**The update site is not found.** Check the URL for typing mistakes, including the `/` at the end, and that the computer is online.

**A workflow stops with an error or gives numbers that look wrong.** Please open an issue on this repository with the version from the About window, what you did, and the message or a screenshot.
