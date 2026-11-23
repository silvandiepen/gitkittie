(function () {
  const root = document.querySelector("[data-lezin-root]");
  let isEditable = true;
  let dirty = false;
  let selectedImage = null;
  let selectionMenu = null;
  let blockMenu = null;
  let undoStack = [];
  let redoStack = [];
  let lastUndoHTML = "";
  let suppressUndoCapture = false;
  let isRestoringHistory = false;
  let sourceMarkdown = "";
  let currentNizelOptions = {};
  const maxUndoEntries = 100;

  const hasNizelKit = typeof NizelKit !== "undefined" && NizelKit && typeof NizelKit.markdownToHtml === "function";
  const fallbackNizel = !hasNizelKit && typeof Nizel !== "undefined" ? Nizel.useBrowserNizel() : null;

  const editableSelectors = [
    "h1", "h2", "h3", "h4", "h5", "h6",
    "p", "li", "blockquote p", "code",
    "td", "th"
  ];

  function notify(type, payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lezin) {
      window.webkit.messageHandlers.lezin.postMessage({ type: type, ...(payload || {}) });
    }
  }

  function setDirty(nextDirty) {
    if (nextDirty) captureUndoSnapshotIfNeeded();
    if (dirty === nextDirty) return;
    dirty = nextDirty;
    notify("dirtyChanged", { dirty: dirty });
  }

  function trimUndoStack() {
    if (undoStack.length > maxUndoEntries) {
      undoStack.splice(0, undoStack.length - maxUndoEntries);
    }
  }

  function resetUndoHistory() {
    undoStack = [];
    redoStack = [];
    lastUndoHTML = root.innerHTML;
  }

  function captureUndoSnapshotIfNeeded() {
    if (suppressUndoCapture || isRestoringHistory) return;

    var currentHTML = root.innerHTML;
    if (currentHTML === lastUndoHTML) return;

    undoStack.push(lastUndoHTML);
    trimUndoStack();
    redoStack = [];
    lastUndoHTML = currentHTML;
  }

  function recordUndoChange(beforeHTML) {
    var currentHTML = root.innerHTML;
    if (currentHTML === beforeHTML) return false;

    undoStack.push(beforeHTML);
    trimUndoStack();
    redoStack = [];
    lastUndoHTML = currentHTML;
    setDirty(true);
    return true;
  }

  function withUndoAction(action) {
    var beforeHTML = lastUndoHTML || root.innerHTML;
    suppressUndoCapture = true;
    var result = false;
    try {
      result = action();
    } finally {
      suppressUndoCapture = false;
    }

    if (result === false) return false;
    return recordUndoChange(beforeHTML);
  }

  function restoreHistoryHTML(html) {
    isRestoringHistory = true;
    try {
      clearSelectedImage();
      hideSelectionMenu();
      hideBlockMenu();
      root.innerHTML = html;
      markEditable();
      lastUndoHTML = html;
      setDirty(true);
    } finally {
      isRestoringHistory = false;
    }
  }

  function undoHistory() {
    if (!undoStack.length) return false;

    var currentHTML = root.innerHTML;
    var previousHTML = undoStack.pop();
    if (currentHTML !== lastUndoHTML) {
      redoStack.push(currentHTML);
    } else {
      redoStack.push(lastUndoHTML);
    }
    restoreHistoryHTML(previousHTML);
    return true;
  }

  function redoHistory() {
    if (!redoStack.length) return false;

    var currentHTML = root.innerHTML;
    var nextHTML = redoStack.pop();
    if (currentHTML !== lastUndoHTML) {
      undoStack.push(currentHTML);
    } else {
      undoStack.push(lastUndoHTML);
    }
    trimUndoStack();
    restoreHistoryHTML(nextHTML);
    return true;
  }

  function handleUndoShortcut(event) {
    if (!event.metaKey || event.altKey || event.ctrlKey || event.key.toLowerCase() !== "z") return false;

    var handled = event.shiftKey ? redoHistory() : undoHistory();
    if (!handled) return false;

    event.preventDefault();
    event.stopPropagation();
    return true;
  }

  function selectImage(image) {
    if (selectedImage === image) return;
    clearSelectedImage();
    selectedImage = image;
    selectedImage.dataset.lezinSelectedImage = "true";
  }

  function clearSelectedImage() {
    if (!selectedImage) return;
    selectedImage.removeAttribute("data-lezin-selected-image");
    selectedImage = null;
  }

  function removeSelectedImage() {
    if (!selectedImage || !isEditable) return false;

    var image = selectedImage;
    clearSelectedImage();
    image.remove();
    setDirty(true);
    return true;
  }

  function markEditable() {
    root.querySelectorAll("[data-lezin-editable]").forEach(function (element) {
      element.removeAttribute("data-lezin-editable");
      element.removeAttribute("contenteditable");
    });

    if (isEditable) {
      root.setAttribute("contenteditable", "plaintext-only");
    } else {
      root.setAttribute("contenteditable", "false");
    }

    editableSelectors.forEach(function (selector) {
      root.querySelectorAll(selector).forEach(function (element) {
        element.dataset.lezinEditable = element.tagName.toLowerCase() === "code" ? "code" : "text";
      });
    });
    setTaskCheckboxesInteractive(root);
  }

  // Relative image paths in the document resolve against the document's folder,
  // not the bundled preview shell. Route local images through a custom scheme
  // that the app serves from the correct location, and restore the original
  // paths when exporting HTML back to Markdown.
  var ASSET_SCHEME = "lezin-asset";

  function isExternalSrc(src) {
    return /^(https?:|data:|blob:|lezin-asset:|#|mailto:|tel:)/i.test(src);
  }

  function toAssetURL(src) {
    if (!src || isExternalSrc(src)) return src;
    if (src.charAt(0) === "/") {
      return ASSET_SCHEME + "://abs/" + encodeURIComponent(src);
    }
    return ASSET_SCHEME + "://doc/" + encodeURIComponent(src);
  }

  function fromAssetURL(src) {
    var absPrefix = ASSET_SCHEME + "://abs/";
    var docPrefix = ASSET_SCHEME + "://doc/";
    if (src.indexOf(absPrefix) === 0) return decodeURIComponent(src.substring(absPrefix.length));
    if (src.indexOf(docPrefix) === 0) return decodeURIComponent(src.substring(docPrefix.length));
    return src;
  }

  function rewriteImagesForDisplay(scope) {
    scope.querySelectorAll("img[src]").forEach(function (img) {
      img.setAttribute("src", toAssetURL(img.getAttribute("src")));
    });
    scope.querySelectorAll("image[href]").forEach(function (image) {
      image.setAttribute("href", toAssetURL(image.getAttribute("href")));
    });
  }

  function restoreImagePaths(scope) {
    scope.querySelectorAll("img[src]").forEach(function (img) {
      var src = img.getAttribute("src") || "";
      if (src.indexOf(ASSET_SCHEME + "://") === 0) {
        img.setAttribute("src", fromAssetURL(src));
      }
    });
    scope.querySelectorAll("image[href]").forEach(function (image) {
      var href = image.getAttribute("href") || "";
      if (href.indexOf(ASSET_SCHEME + "://") === 0) {
        image.setAttribute("href", fromAssetURL(href));
      }
    });
  }

  function normalizeNizelOptions(options) {
    var normalized = options && typeof options === "object" ? { ...options } : {};
    if (hasNizelKit) {
      if (!Array.isArray(normalized.enabledPlugins) && Array.isArray(normalized.plugins)) {
        normalized.enabledPlugins = normalized.plugins;
      }
      if (normalized["task-list"] && !normalized.pluginOptions) {
        normalized.pluginOptions = { "task-list": normalized["task-list"] };
      } else if (normalized["task-list"] && typeof normalized.pluginOptions === "object") {
        normalized.pluginOptions = { ...normalized.pluginOptions, "task-list": normalized["task-list"] };
      }
      var pluginOptions = normalized.pluginOptions && typeof normalized.pluginOptions === "object"
        ? { ...normalized.pluginOptions }
        : {};
      if (!pluginOptions["hidden-comments"]) {
        pluginOptions["hidden-comments"] = { mode: "hide" };
      }
      normalized.pluginOptions = pluginOptions;
      delete normalized.plugins;
    }
    return normalized;
  }

  function hiddenCommentsModeFromOptions(options) {
    var pluginOptions = options && typeof options.pluginOptions === "object" ? options.pluginOptions : {};
    var hiddenOptions = pluginOptions["hidden-comments"] && typeof pluginOptions["hidden-comments"] === "object"
      ? pluginOptions["hidden-comments"]
      : {};
    var mode = hiddenOptions.mode || "hide";
    return ["hide", "small", "render", "remove"].indexOf(mode) === -1 ? "hide" : mode;
  }

  function hiddenCommentsEnabledFromOptions(options) {
    return Array.isArray(options && options.enabledPlugins)
      && options.enabledPlugins.indexOf("hidden-comments") !== -1;
  }

  function createHiddenCommentElement(comment, mode) {
    var span = document.createElement("span");
    span.className = "nizel-hidden-comment nizel-hidden-comment--" + mode + " print-hidden-comment";
    span.dataset.nizelHiddenComment = "";
    span.dataset.hiddenCommentMode = mode;
    span.contentEditable = "false";
    span.textContent = comment;
    return span;
  }

  function prepareHiddenComments(scope, options) {
    if (!hiddenCommentsEnabledFromOptions(options)) return;

    var mode = hiddenCommentsModeFromOptions(options);

    scope.querySelectorAll("[data-nizel-hidden-comment]").forEach(function (element) {
      element.setAttribute("contenteditable", "false");
      element.classList.remove(
        "nizel-hidden-comment--hide",
        "nizel-hidden-comment--small",
        "nizel-hidden-comment--render",
        "nizel-hidden-comment--remove"
      );
      element.classList.add("nizel-hidden-comment", "nizel-hidden-comment--" + mode, "print-hidden-comment");
      element.dataset.hiddenCommentMode = mode;
    });

    var textNodes = [];
    var walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue || node.nodeValue.indexOf("<!--") === -1) return NodeFilter.FILTER_REJECT;
        var parent = node.parentElement;
        if (!parent) return NodeFilter.FILTER_REJECT;
        if (parent.closest("pre, code, script, style, [data-nizel-hidden-comment]")) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    while (walker.nextNode()) {
      textNodes.push(walker.currentNode);
    }

    textNodes.forEach(function (node) {
      var text = node.nodeValue || "";
      var fragment = document.createDocumentFragment();
      var lastIndex = 0;
      var match;
      var pattern = /<!--[\s\S]*?-->/g;

      while ((match = pattern.exec(text)) !== null) {
        if (match.index > lastIndex) {
          fragment.appendChild(document.createTextNode(text.slice(lastIndex, match.index)));
        }
        if (mode !== "remove") {
          fragment.appendChild(createHiddenCommentElement(match[0], mode));
        }
        lastIndex = match.index + match[0].length;
      }

      if (lastIndex < text.length) {
        fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
      }

      node.parentNode.replaceChild(fragment, node);
    });
  }

  function preparePrintControls(scope) {
    scope.querySelectorAll("p, div").forEach(function (node) {
      if (node.children.length > 0) return;
      var text = (node.textContent || "").trim().toLowerCase();
      var normalized = text.replace(/\s+/g, " ");
      if (/^:{3,}\s*pagebreak(?:\s+:{3,})?$/.test(normalized) || normalized === "[[pagebreak]]") {
        var breakNode = document.createElement("div");
        breakNode.className = "nizel-pagebreak page-break";
        breakNode.setAttribute("aria-hidden", "true");
        node.replaceWith(breakNode);
      }
    });
  }

  function syncTaskCheckboxAttribute(checkbox) {
    if (!checkbox || checkbox.type !== "checkbox") return;
    if (checkbox.checked) {
      checkbox.setAttribute("checked", "");
    } else {
      checkbox.removeAttribute("checked");
    }
  }

  function setTaskCheckboxesInteractive(scope) {
    scope.querySelectorAll("input[data-nizel-task-checkbox][type='checkbox']").forEach(function (checkbox) {
      checkbox.disabled = !isEditable;
      syncTaskCheckboxAttribute(checkbox);
    });
  }

  async function renderMarkdown(markdown, options) {
    clearSelectedImage();
    sourceMarkdown = typeof markdown === "string" ? markdown : "";
    var normalizedOptions = normalizeNizelOptions(options);
    currentNizelOptions = normalizedOptions;
    var html = hasNizelKit
      ? await NizelKit.markdownToHtml(sourceMarkdown, normalizedOptions)
      : await fallbackNizel.html(sourceMarkdown, normalizedOptions);
    root.innerHTML = html;
    prepareHiddenComments(root, normalizedOptions);
    preparePrintControls(root);
    rewriteImagesForDisplay(root);
    markEditable();
    setTaskCheckboxesInteractive(root);
    setDirty(false);
    resetUndoHistory();
    return { html: html, diagnostics: [] };
  }

  function normalizeTaskListHtmlForMarkdown(html) {
    if (typeof html !== "string" || html.indexOf("data-nizel-task-checkbox") === -1) {
      return html;
    }
    var template = document.createElement("template");
    template.innerHTML = html;
    template.content.querySelectorAll("li").forEach(function (item) {
      var checkbox = item.querySelector("input[data-nizel-task-checkbox][type='checkbox']");
      if (!checkbox) return;
      var checked = checkbox.checked || checkbox.hasAttribute("checked");
      checkbox.remove();
      var text = (item.textContent || "").trim();
      item.textContent = (checked ? "[x] " : "[ ] ") + text;
    });
    return template.innerHTML;
  }

  function htmlToMarkdown(html) {
    var processor = hasNizelKit ? NizelKit.useNizelKit(currentNizelOptions) : fallbackNizel;
    var normalizedHtml = normalizeTaskListHtmlForMarkdown(html);
    var md = processor.htmlToMarkdown(normalizedHtml);
    return { markdown: md, diagnostics: [] };
  }

  function getCleanHtml() {
    var clone = root.cloneNode(true);

    restoreImagePaths(clone);

    clone.querySelectorAll("[contenteditable]").forEach(function (el) {
      el.removeAttribute("contenteditable");
    });
    clone.querySelectorAll("[data-lezin-ui]").forEach(function (el) {
      el.remove();
    });
    clone.querySelectorAll("[style]").forEach(function (el) {
      el.removeAttribute("style");
    });
    clone.querySelectorAll("[data-lezin-editable]").forEach(function (el) {
      el.removeAttribute("data-lezin-editable");
    });
    clone.querySelectorAll("[data-lezin-selected-image]").forEach(function (el) {
      el.removeAttribute("data-lezin-selected-image");
    });

    return clone.innerHTML;
  }

  function setEditable(nextEditable) {
    isEditable = !!nextEditable;
    markEditable();
  }

  function markClean() {
    setDirty(false);
  }

  function getSelection() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return null;
    return { text: sel.toString() };
  }

  function selectionCoversRoot() {
    var selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return false;

    var selectedRange = selection.getRangeAt(0);
    var rootRange = document.createRange();
    rootRange.selectNodeContents(root);

    return selectedRange.compareBoundaryPoints(Range.START_TO_START, rootRange) <= 0
      && selectedRange.compareBoundaryPoints(Range.END_TO_END, rootRange) >= 0;
  }

  function setScrollPosition(position) {
    var x = (position && typeof position.x === "number") ? position.x : 0;
    var y = (position && typeof position.y === "number") ? position.y : 0;
    window.scrollTo(x, y);
  }

  function closestEditableListItem(node) {
    var element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
    var item = element && element.closest ? element.closest("li[data-lezin-editable]") : null;
    return item && root.contains(item) ? item : null;
  }

  function editableListItemFromEvent(event) {
    var selection = window.getSelection();
    if (selection && selection.rangeCount > 0) {
      var range = selection.getRangeAt(0);
      var selectedItem = closestEditableListItem(range.startContainer);
      if (selectedItem && selectedItem === closestEditableListItem(range.endContainer)) {
        return selectedItem;
      }
    }

    return closestEditableListItem(event.target);
  }

  function selectionOffsetsWithin(element) {
    var selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return null;

    var range = selection.getRangeAt(0);
    if (!element.contains(range.startContainer) || !element.contains(range.endContainer)) return null;

    var startRange = range.cloneRange();
    startRange.selectNodeContents(element);
    startRange.setEnd(range.startContainer, range.startOffset);

    var endRange = range.cloneRange();
    endRange.selectNodeContents(element);
    endRange.setEnd(range.endContainer, range.endOffset);

    return {
      start: startRange.toString().length,
      end: endRange.toString().length
    };
  }

  function focusTextOffset(element, offset) {
    var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    var remaining = offset;
    var node = walker.nextNode();

    while (node) {
      if (remaining <= node.nodeValue.length) {
        var range = document.createRange();
        range.setStart(node, remaining);
        range.collapse(true);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        return;
      }

      remaining -= node.nodeValue.length;
      node = walker.nextNode();
    }

    if (!element.firstChild) {
      element.appendChild(document.createTextNode(""));
    }

    var fallbackRange = document.createRange();
    fallbackRange.selectNodeContents(element);
    fallbackRange.collapse(false);
    var fallbackSelection = window.getSelection();
    fallbackSelection.removeAllRanges();
    fallbackSelection.addRange(fallbackRange);
  }

  function insertTextIntoElement(element, value) {
    var offsets = selectionOffsetsWithin(element);
    if (!offsets) return false;

    var text = element.textContent || "";
    element.textContent = text.slice(0, offsets.start) + value + text.slice(offsets.end);
    focusTextOffset(element, offsets.start + value.length);
    setDirty(true);
    return true;
  }

  function selectedRange() {
    var selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return null;
    return selection.getRangeAt(0);
  }

  function closestElement(node, selector) {
    var element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
    var match = element && element.closest ? element.closest(selector) : null;
    return match && root.contains(match) ? match : null;
  }

  function createEditableParagraph() {
    var paragraph = document.createElement("p");
    paragraph.dataset.lezinEditable = "text";
    paragraph.appendChild(document.createTextNode(""));
    return paragraph;
  }

  function createEditableHeading(level, text) {
    var heading = document.createElement("h" + level);
    heading.dataset.lezinEditable = "text";
    heading.textContent = text || "";
    return heading;
  }

  function createEditableImage(src, alt) {
    var image = document.createElement("img");
    image.src = src || "";
    image.alt = alt || "";
    return image;
  }

  function createEditableCodeBlock(text) {
    var pre = document.createElement("pre");
    var code = document.createElement("code");
    code.dataset.lezinEditable = "code";
    code.textContent = text || "";
    pre.appendChild(code);
    return { pre: pre, code: code };
  }

  function replaceElement(newElement, oldElement, focusOffset) {
    oldElement.replaceWith(newElement);
    focusTextOffset(newElement, typeof focusOffset === "number" ? focusOffset : newElement.textContent.length);
    setDirty(true);
    return true;
  }

  function createListFromParagraph(paragraph, ordered, text, taskChecked) {
    var list = document.createElement(ordered ? "ol" : "ul");
    var item = createEditableListItem(taskChecked === null || taskChecked === undefined ? (text || "") : "");

    if (taskChecked !== null && taskChecked !== undefined) {
      list.className = "task-list";
      item.className = "task-list-item";
      var checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.disabled = true;
      checkbox.checked = !!taskChecked;
      item.insertBefore(checkbox, item.firstChild);
      item.appendChild(document.createTextNode(text || ""));
    }

    list.appendChild(item);
    paragraph.replaceWith(list);
    focusTextOffset(item, item.textContent.length);
    setDirty(true);
    return true;
  }

  function createListFromTexts(texts, ordered, task, checkedValues) {
    var list = document.createElement(ordered ? "ol" : "ul");
    if (task) list.className = "task-list";

    texts.forEach(function (text, index) {
      var item = createEditableListItem(task ? "" : text);
      if (task) {
        item.className = "task-list-item";
        var checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.disabled = true;
        checkbox.checked = !!(checkedValues && checkedValues[index]);
        item.appendChild(checkbox);
        item.appendChild(document.createTextNode(text || ""));
      }
      list.appendChild(item);
    });

    if (!list.children.length) {
      list.appendChild(createEditableListItem(""));
    }

    return list;
  }

  function unwrapList(list) {
    var fragment = document.createDocumentFragment();
    var firstParagraph = null;

    Array.from(list.children).forEach(function (item) {
      if (item.tagName.toLowerCase() !== "li") return;
      var paragraph = createEditableParagraph();
      paragraph.textContent = item.textContent || "";
      if (!firstParagraph) firstParagraph = paragraph;
      fragment.appendChild(paragraph);
    });

    list.replaceWith(fragment);
    if (firstParagraph) focusTextOffset(firstParagraph, firstParagraph.textContent.length);
    setDirty(true);
    return true;
  }

  function setListTaskState(list, task) {
    list.classList.toggle("task-list", task);
    Array.from(list.children).forEach(function (item) {
      if (item.tagName.toLowerCase() !== "li") return;
      item.classList.toggle("task-list-item", task);
      var checkbox = item.querySelector(":scope > input[type='checkbox']");
      if (task && !checkbox) {
        checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.disabled = true;
        checkbox.checked = false;
        item.insertBefore(checkbox, item.firstChild);
      } else if (!task && checkbox) {
        checkbox.remove();
      }
    });
  }

  function changeListType(list, ordered, task) {
    var replacement = document.createElement(ordered ? "ol" : "ul");
    Array.from(list.attributes).forEach(function (attr) {
      if (attr.name !== "class") replacement.setAttribute(attr.name, attr.value);
    });
    while (list.firstChild) replacement.appendChild(list.firstChild);
    setListTaskState(replacement, !!task);
    list.replaceWith(replacement);
    setDirty(true);
    return true;
  }

  function setBlockHeading(block, level) {
    var replacement = level === 0 ? createEditableParagraph() : createEditableHeading(level);
    replacement.textContent = block.textContent || "";
    return replaceElement(replacement, block);
  }

  function topLevelBlockFor(node) {
    var element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
    if (!element) return null;
    if (element.closest("li")) return element.closest("li");
    while (element && element.parentElement !== root) {
      element = element.parentElement;
    }
    return element && root.contains(element) ? element : null;
  }

  function conversionBlockFor(node) {
    var element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
    if (!element) return null;

    var listItem = element.closest("li");
    if (listItem && root.contains(listItem)) return listItem;

    var pre = element.closest("pre");
    if (pre && root.contains(pre)) return pre;

    var table = element.closest("table");
    if (table && root.contains(table)) return table;

    var quote = element.closest("blockquote");
    if (quote && root.contains(quote)) return quote;

    return closestElement(element, "h1,h2,h3,h4,h5,h6,p,pre,table");
  }

  function selectedBlocksOr(target) {
    var range = selectedRange();
    var blocks = [];

    if (range && !range.collapsed && root.contains(range.commonAncestorContainer)) {
      root.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,table,td,th").forEach(function (block) {
        try {
          if (range.intersectsNode(block)) {
            var conversionBlock = conversionBlockFor(block);
            if (conversionBlock) blocks.push(conversionBlock);
          }
        } catch (_) {}
      });
    }

    if (!blocks.length) {
      var targetBlock = conversionBlockFor(target);
      if (targetBlock) blocks.push(targetBlock);
    }

    return Array.from(new Set(blocks)).sort(function (first, second) {
      if (first === second) return 0;
      return first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
    });
  }

  function blockText(block) {
    return (block.textContent || "").replace(/\n+$/g, "");
  }

  function tableRowTexts(table) {
    return Array.from(table.querySelectorAll("tr")).map(function (row) {
      return Array.from(row.children).filter(function (cell) {
        var tagName = cell.tagName && cell.tagName.toLowerCase();
        return tagName === "td" || tagName === "th";
      }).map(function (cell) {
        return (cell.textContent || "").replace(/\s+/g, " ").trim();
      }).filter(Boolean).join("\t");
    }).filter(Boolean);
  }

  function tableToParagraphs(table) {
    var rows = tableRowTexts(table);
    if (!rows.length) rows = [blockText(table)];
    return rows.map(function (text) {
      var paragraph = createEditableParagraph();
      paragraph.textContent = text;
      return paragraph;
    });
  }

  function replaceBlocksWith(blocks, replacements, focusElement) {
    if (!blocks.length || !replacements.length) return false;
    var first = blocks[0];
    var parent = first.parentElement;
    if (!blocks.every(function (block) { return block.parentElement === parent; })) return false;
    replacements.forEach(function (element) {
      parent.insertBefore(element, first);
    });
    blocks.forEach(function (block) {
      if (block.parentElement) block.remove();
    });
    focusTextOffset(focusElement || replacements[0], (focusElement || replacements[0]).textContent.length);
    setDirty(true);
    return true;
  }

  function selectedListContext(blocks) {
    if (!blocks.length) return null;
    var list = null;
    var indexes = [];

    for (var index = 0; index < blocks.length; index += 1) {
      var block = blocks[index];
      if (!block.tagName || block.tagName.toLowerCase() !== "li") return null;
      if (!list) list = block.parentElement;
      if (block.parentElement !== list) return null;
      indexes.push(Array.prototype.indexOf.call(list.children, block));
    }

    indexes.sort(function (first, second) { return first - second; });
    var firstIndex = indexes[0];
    var lastIndex = indexes[indexes.length - 1];
    if (firstIndex < 0 || lastIndex < firstIndex) return null;
    if (lastIndex - firstIndex + 1 !== indexes.length) return null;

    return {
      list: list,
      firstIndex: firstIndex,
      lastIndex: lastIndex,
      allItems: firstIndex === 0 && lastIndex === list.children.length - 1
    };
  }

  function replaceSelectedListItemsWithBlocks(context, replacements, focusElement) {
    if (!context || !replacements.length) return false;
    var list = context.list;
    var parent = list.parentElement;
    if (!parent) return false;

    var children = Array.from(list.children);
    var selectedItems = children.slice(context.firstIndex, context.lastIndex + 1);
    var trailingItems = children.slice(context.lastIndex + 1);
    var trailingList = trailingItems.length ? list.cloneNode(false) : null;

    selectedItems.forEach(function (item) {
      if (item.parentElement) item.remove();
    });
    trailingItems.forEach(function (item) {
      trailingList.appendChild(item);
    });

    var insertionPoint = list.nextSibling;
    replacements.forEach(function (element) {
      parent.insertBefore(element, insertionPoint);
    });
    if (trailingList && trailingList.children.length) {
      parent.insertBefore(trailingList, insertionPoint);
    }
    if (!list.children.length) {
      list.remove();
    }

    focusTextOffset(focusElement || replacements[0], (focusElement || replacements[0]).textContent.length);
    setDirty(true);
    return true;
  }

  function replaceBlocksOneForOne(blocks, replacements, focusElement) {
    if (!blocks.length || blocks.length !== replacements.length) return false;
    if (replaceBlocksWith(blocks, replacements, focusElement)) return true;

    for (var index = blocks.length - 1; index >= 0; index -= 1) {
      var block = blocks[index];
      var replacement = replacements[index];
      if (block.tagName && block.tagName.toLowerCase() === "li") {
        if (!replaceSelectedListItemsWithBlocks(selectedListContext([block]), [replacement], replacement)) return false;
      } else if (block.parentElement) {
        block.parentElement.insertBefore(replacement, block);
        block.remove();
        setDirty(true);
      } else {
        return false;
      }
    }

    focusTextOffset(focusElement || replacements[0], (focusElement || replacements[0]).textContent.length);
    setDirty(true);
    return true;
  }

  function convertBlocksToParagraphs(blocks) {
    var listContext = selectedListContext(blocks);
    if (listContext) {
      var selectedItems = Array.from(listContext.list.children).slice(listContext.firstIndex, listContext.lastIndex + 1);
      var paragraphs = selectedItems.map(function (item) {
        var paragraph = createEditableParagraph();
        paragraph.textContent = blockText(item);
        return paragraph;
      });
      return replaceSelectedListItemsWithBlocks(listContext, paragraphs, paragraphs[0]);
    }

    var replacements = [];
    blocks.forEach(function (block) {
      if (block.tagName && block.tagName.toLowerCase() === "table") {
        replacements = replacements.concat(tableToParagraphs(block));
      } else {
        var paragraph = createEditableParagraph();
        paragraph.textContent = blockText(block);
        replacements.push(paragraph);
      }
    });

    if (blocks.length === replacements.length) {
      return replaceBlocksOneForOne(blocks, replacements, replacements[0]);
    }

    return replaceBlocksWith(blocks, replacements, replacements[0]);
  }

  function convertBlocksToHeading(blocks, level) {
    if (level === 0) return convertBlocksToParagraphs(blocks);
    var listContext = selectedListContext(blocks);
    if (listContext) {
      var selectedItems = Array.from(listContext.list.children).slice(listContext.firstIndex, listContext.lastIndex + 1);
      var headings = selectedItems.map(function (item) {
        return createEditableHeading(level, blockText(item));
      });
      return replaceSelectedListItemsWithBlocks(listContext, headings, headings[0]);
    }

    var replacements = blocks.map(function (block) {
      return createEditableHeading(level, blockText(block));
    });
    return replaceBlocksOneForOne(blocks, replacements, replacements[0]);
  }

  function convertBlocksToList(blocks, ordered, task) {
    var listContext = selectedListContext(blocks);
    if (listContext) {
      if (listContext.allItems) {
        return changeListType(listContext.list, ordered, task);
      }

      var selectedItems = Array.from(listContext.list.children).slice(listContext.firstIndex, listContext.lastIndex + 1);
      var list = createListFromTexts(selectedItems.map(blockText), ordered, task);
      return replaceSelectedListItemsWithBlocks(listContext, [list], list.querySelector("li"));
    }

    var texts = [];
    blocks.forEach(function (block) {
      if (block.tagName && (block.tagName.toLowerCase() === "ul" || block.tagName.toLowerCase() === "ol")) {
        Array.from(block.children).forEach(function (item) {
          if (item.tagName.toLowerCase() === "li") texts.push(blockText(item));
        });
      } else {
        texts.push(blockText(block));
      }
    });

    var list = createListFromTexts(texts, ordered, task);
    return replaceBlocksWith(blocks, [list], list.querySelector("li"));
  }

  function parseMarkdownListLine(line) {
    var text = (line || "").trim();
    var task = /^[-*+]\s+\[( |x|X)\]\s+(.+)$/.exec(text);
    if (task) {
      return { kind: "task", ordered: false, task: true, checked: task[1].toLowerCase() === "x", text: task[2] };
    }

    var unordered = /^[-*+]\s+(.+)$/.exec(text);
    if (unordered) {
      return { kind: "unordered", ordered: false, task: false, checked: false, text: unordered[1] };
    }

    var ordered = /^\d+[.)]\s+(.+)$/.exec(text);
    if (ordered) {
      return { kind: "ordered", ordered: true, task: false, checked: false, text: ordered[1] };
    }

    return null;
  }

  function matchingListLines(lines) {
    var parsed = lines.map(parseMarkdownListLine);
    if (!parsed.length || !parsed.every(Boolean)) return null;
    var firstKind = parsed[0].kind;
    if (!parsed.every(function (line) { return line.kind === firstKind; })) return null;
    return parsed;
  }

  function replaceMarkdownLinesWithList(anchor, lines, blocksToRemove) {
    var parsed = matchingListLines(lines);
    if (!parsed || parsed.length < 2) return false;

    var list = createListFromTexts(
      parsed.map(function (line) { return line.text; }),
      parsed[0].ordered,
      parsed[0].task,
      parsed.map(function (line) { return line.checked; })
    );

    anchor.replaceWith(list);
    blocksToRemove.forEach(function (block) {
      if (block.parentElement) block.remove();
    });
    focusTextOffset(list.querySelector("li"), list.querySelector("li").textContent.length);
    setDirty(true);
    return true;
  }

  function normalizePlainMarkdownBlock(block) {
    if (!block || block.tagName.toLowerCase() !== "p") return false;
    var text = block.textContent || "";
    if (text.indexOf("\n") === -1) return false;

    var lines = text.split(/\n/).map(function (line) { return line.trim(); }).filter(Boolean);
    return replaceMarkdownLinesWithList(block, lines, []);
  }

  function normalizeAdjacentMarkdownListBlocks() {
    var changed = false;
    var children = Array.from(root.children);

    for (var index = 0; index < children.length; index += 1) {
      var child = children[index];
      if (!child.parentElement || child.tagName.toLowerCase() !== "p") continue;

      var run = [];
      var lines = [];
      var lookahead = index;
      var expectedKind = null;

      while (lookahead < children.length) {
        var candidate = children[lookahead];
        if (!candidate.parentElement || candidate.tagName.toLowerCase() !== "p") break;

        var parsed = parseMarkdownListLine(candidate.textContent || "");
        if (!parsed) break;
        if (expectedKind && parsed.kind !== expectedKind) break;
        expectedKind = parsed.kind;
        run.push(candidate);
        lines.push(candidate.textContent || "");
        lookahead += 1;
      }

      if (run.length > 1 && replaceMarkdownLinesWithList(run[0], lines, run.slice(1))) {
        changed = true;
        index = lookahead - 1;
      }
    }

    return changed;
  }

  function normalizePlainMarkdownBlocks() {
    var changed = false;
    root.querySelectorAll("p[data-lezin-editable]").forEach(function (paragraph) {
      if (normalizePlainMarkdownBlock(paragraph)) changed = true;
    });
    if (normalizeAdjacentMarkdownListBlocks()) changed = true;
    if (changed) markEditable();
    return changed;
  }

  function selectedTextRange() {
    var range = selectedRange();
    if (!range || range.collapsed || !root.contains(range.commonAncestorContainer)) return null;
    return range;
  }

  function closestInlineFormat(node) {
    var element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
    var inline = element && element.closest ? element.closest("strong,b,em,i,code,a,del,s,mark") : null;
    if (!inline || !root.contains(inline)) return null;
    if (inline.tagName && inline.tagName.toLowerCase() === "code" && inline.closest("pre")) return null;
    return inline;
  }

  function selectedInlineFormatOr(target) {
    var range = selectedRange();
    if (range && !range.collapsed && root.contains(range.commonAncestorContainer)) {
      var selectedInline = closestInlineFormat(range.commonAncestorContainer);
      if (selectedInline && selectedInline.contains(range.startContainer) && selectedInline.contains(range.endContainer)) {
        return selectedInline;
      }
    }

    return closestInlineFormat(target);
  }

  function unwrapInlineFormat(element) {
    if (!element || !element.parentElement) return false;

    var parent = element.parentElement;
    var focusNode = element.nextSibling;
    while (element.firstChild) {
      parent.insertBefore(element.firstChild, element);
    }
    element.remove();
    focusTextOffset(parent, parent.textContent.length);
    setDirty(true);
    return true;
  }

  function wrapSelectionInline(tagName) {
    var range = selectedTextRange();
    if (!range) return false;

    var wrapper = document.createElement(tagName);
    try {
      wrapper.appendChild(range.extractContents());
      range.insertNode(wrapper);
      focusTextOffset(wrapper, wrapper.textContent.length);
      setDirty(true);
      hideSelectionMenu();
      return true;
    } catch (_) {
      return false;
    }
  }

  function applyInlineCommand(command) {
    switch (command) {
    case "bold":
      return wrapSelectionInline("strong");
    case "italic":
      return wrapSelectionInline("em");
    case "code":
      return wrapSelectionInline("code");
    case "strike":
    case "strikethrough":
      return wrapSelectionInline("del");
    default:
      return false;
    }
  }

  /// Formatting commands from the native side (Format menu, toolbar) — the same
  /// vocabulary as MarkdownFormatAction.
  function applyFormatCommand(name) {
    switch (name) {
    case "bold":
    case "italic":
    case "code":
    case "strikethrough":
      return withUndoAction(function () { return applyInlineCommand(name); });
    }
    var anchor = window.getSelection() && window.getSelection().anchorNode;
    var blocks = selectedBlocksOr(anchor || null);
    if (!blocks || !blocks.length) return false;
    switch (name) {
    case "heading1": return withUndoAction(function () { convertBlocksToHeading(blocks, 1); });
    case "heading2": return withUndoAction(function () { convertBlocksToHeading(blocks, 2); });
    case "heading3": return withUndoAction(function () { convertBlocksToHeading(blocks, 3); });
    case "bulletList": return withUndoAction(function () { convertBlocksToList(blocks, false, false); });
    case "orderedList": return withUndoAction(function () { convertBlocksToList(blocks, true, false); });
    case "quote": return withUndoAction(function () { return convertBlocksToQuote(blocks); });
    case "plainText": return withUndoAction(function () {
      var target = selectedInlineFormatOr(anchor);
      while (target) {
        unwrapInlineFormat(target);
        target = selectedInlineFormatOr(window.getSelection() && window.getSelection().anchorNode);
      }
      convertBlocksToParagraphs(blocks);
      return true;
    });
    }
    return false;
  }

  /// Wrap the selected blocks in a blockquote (or unwrap when already quoted).
  function convertBlocksToQuote(blocks) {
    if (!blocks.length) return false;
    var existing = closestElement(blocks[0], "blockquote");
    if (existing) {
      var parent = existing.parentElement;
      while (existing.firstChild) parent.insertBefore(existing.firstChild, existing);
      existing.remove();
      setDirty(true);
      return true;
    }
    var quote = document.createElement("blockquote");
    blocks[0].parentElement.insertBefore(quote, blocks[0]);
    blocks.forEach(function (block) { quote.appendChild(block); });
    setDirty(true);
    return true;
  }

  function handleInlineShortcut(event) {
    if (!event.metaKey || event.altKey || event.ctrlKey) return false;

    var key = event.key.toLowerCase();
    var command = null;
    if (event.shiftKey) {
      if (key === "x") command = "strike";
      if (!command) return false;
    } else {
      if (key === "b") command = "bold";
      if (key === "i") command = "italic";
      if (event.key === "`") command = "code";
    }
    if (!command) return false;

    if (!applyInlineCommand(command)) return false;
    event.preventDefault();
    event.stopPropagation();
    return true;
  }

  function handleMarkdownShortcut(event) {
    if (event.metaKey || event.shiftKey || event.altKey || event.ctrlKey) return false;

    var range = selectedRange();
    if (!range || !range.collapsed) return false;

    var paragraph = closestElement(range.startContainer, "p[data-lezin-editable]");
    if (!paragraph) return false;

    var offsets = selectionOffsetsWithin(paragraph);
    if (!offsets) return false;

    var text = paragraph.textContent || "";
    var before = text.slice(0, offsets.start);
    var after = text.slice(offsets.end);

    if (event.key === " ") {
      var heading = /^(#{1,6})$/.exec(before);
      if (heading && after.trim() === "") {
        event.preventDefault();
        event.stopPropagation();
        return replaceElement(createEditableHeading(heading[1].length, after), paragraph, 0);
      }

      if (before === ">" && after.trim() === "") {
        event.preventDefault();
        event.stopPropagation();
        var quote = document.createElement("blockquote");
        var quoteParagraph = createEditableParagraph();
        quote.appendChild(quoteParagraph);
        paragraph.replaceWith(quote);
        focusTextOffset(quoteParagraph, 0);
        setDirty(true);
        return true;
      }

      if ((before === "-" || before === "*" || before === "+") && after.trim() === "") {
        event.preventDefault();
        event.stopPropagation();
        return createListFromParagraph(paragraph, false, after);
      }

      if (/^\d+\.$/.test(before) && after.trim() === "") {
        event.preventDefault();
        event.stopPropagation();
        return createListFromParagraph(paragraph, true, after);
      }

      if ((before === "- [ ]" || before === "* [ ]") && after.trim() === "") {
        event.preventDefault();
        event.stopPropagation();
        return createListFromParagraph(paragraph, false, after, false);
      }

      if ((before === "- [x]" || before === "- [X]" || before === "* [x]" || before === "* [X]") && after.trim() === "") {
        event.preventDefault();
        event.stopPropagation();
        return createListFromParagraph(paragraph, false, after, true);
      }
    }

    if (event.key === "-" && before === "--" && after.trim() === "") {
      event.preventDefault();
      event.stopPropagation();
      var rule = document.createElement("hr");
      var nextParagraph = createEditableParagraph();
      paragraph.replaceWith(rule, nextParagraph);
      focusTextOffset(nextParagraph, 0);
      setDirty(true);
      return true;
    }

    return false;
  }

  function handleCodeBlockExit(event) {
    if (event.key !== "Enter" || !event.metaKey || event.shiftKey || event.altKey || event.ctrlKey) return false;

    var range = selectedRange();
    if (!range) return false;

    var code = closestElement(range.startContainer, "pre code[data-lezin-editable]");
    if (!code || code !== closestElement(range.endContainer, "pre code[data-lezin-editable]")) return false;

    event.preventDefault();
    event.stopPropagation();

    var paragraph = createEditableParagraph();
    code.closest("pre").insertAdjacentElement("afterend", paragraph);
    focusTextOffset(paragraph, 0);
    setDirty(true);
    return true;
  }

  function handleCodeFenceShortcut(event) {
    if (event.key !== "`" || event.metaKey || event.shiftKey || event.altKey || event.ctrlKey) return false;

    var range = selectedRange();
    if (!range || !range.collapsed) return false;

    var paragraph = closestElement(range.startContainer, "p[data-lezin-editable]");
    if (!paragraph || paragraph !== closestElement(range.endContainer, "p[data-lezin-editable]")) return false;

    var offsets = selectionOffsetsWithin(paragraph);
    if (!offsets) return false;

    var text = paragraph.textContent || "";
    var before = text.slice(0, offsets.start);
    var after = text.slice(offsets.end);
    if (before !== "``" || after.trim() !== "") return false;

    event.preventDefault();
    event.stopPropagation();

    var block = createEditableCodeBlock(after);
    paragraph.replaceWith(block.pre);
    focusTextOffset(block.code, 0);
    setDirty(true);
    return true;
  }

  function createEditableListItem(text) {
    var item = document.createElement("li");
    item.dataset.lezinEditable = "text";
    item.textContent = text;
    return item;
  }

  function splitListItem(item) {
    var offsets = selectionOffsetsWithin(item);
    if (!offsets) return false;

    var text = item.textContent || "";
    var before = text.slice(0, offsets.start);
    var after = text.slice(offsets.end);
    item.textContent = before;

    var nextItem = createEditableListItem(after);
    item.insertAdjacentElement("afterend", nextItem);
    focusTextOffset(nextItem, 0);
    setDirty(true);
    return true;
  }

  function handleListItemEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.altKey || event.ctrlKey) return false;

    var item = editableListItemFromEvent(event);
    if (!item) return false;

    event.preventDefault();
    event.stopPropagation();

    if (event.metaKey) {
      return insertTextIntoElement(item, "\n");
    }

    if (!(item.textContent || "").trim()) {
      var list = item.parentElement;
      var paragraph = createEditableParagraph();
      if (list.children.length === 1) {
        list.replaceWith(paragraph);
      } else {
        var items = Array.from(list.children);
        var itemIndex = items.indexOf(item);
        if (itemIndex <= 0) {
          list.insertAdjacentElement("beforebegin", paragraph);
        } else if (itemIndex >= items.length - 1) {
          list.insertAdjacentElement("afterend", paragraph);
        } else {
          var trailingList = list.cloneNode(false);
          items.slice(itemIndex + 1).forEach(function (nextItem) {
            trailingList.appendChild(nextItem);
          });
          list.insertAdjacentElement("afterend", trailingList);
          list.insertAdjacentElement("afterend", paragraph);
        }
        item.remove();
      }
      focusTextOffset(paragraph, 0);
      setDirty(true);
      return true;
    }

    return splitListItem(item);
  }

  function removeMenu(menu) {
    if (menu && menu.parentElement) menu.parentElement.removeChild(menu);
  }

  function hideSelectionMenu() {
    removeMenu(selectionMenu);
    selectionMenu = null;
    notify("selectionContext", { hidden: true });
  }

  function hideBlockMenu() {
    removeMenu(blockMenu);
    blockMenu = null;
  }

  function menuButton(title, action, icon) {
    var button = document.createElement("button");
    button.type = "button";
    if (icon) {
      var iconElement = document.createElement("span");
      iconElement.className = "lezin-menu-icon";
      iconElement.setAttribute("aria-hidden", "true");
      iconElement.dataset.icon = icon;
      button.appendChild(iconElement);
    }
    var label = document.createElement("span");
    label.textContent = title;
    button.appendChild(label);
    button.addEventListener("mousedown", function (event) {
      event.preventDefault();
      withUndoAction(action);
    });
    return button;
  }

  function menuSeparator() {
    var separator = document.createElement("div");
    separator.className = "lezin-menu-separator";
    return separator;
  }

  function addBlockConversionMenu(menu, blocks, closeMenu) {
    var close = closeMenu || hideBlockMenu;
    menu.appendChild(menuButton("Plain Text", function () { convertBlocksToParagraphs(blocks); close(); }, "T"));
    menu.appendChild(menuButton("Heading 1", function () { convertBlocksToHeading(blocks, 1); close(); }, "H1"));
    menu.appendChild(menuButton("Heading 2", function () { convertBlocksToHeading(blocks, 2); close(); }, "H2"));
    menu.appendChild(menuButton("Heading 3", function () { convertBlocksToHeading(blocks, 3); close(); }, "H3"));
    menu.appendChild(menuButton("Heading 4", function () { convertBlocksToHeading(blocks, 4); close(); }, "H4"));
    menu.appendChild(menuSeparator());
    menu.appendChild(menuButton("Dash List", function () { convertBlocksToList(blocks, false, false); close(); }, "—"));
    menu.appendChild(menuButton("Numbered List", function () { convertBlocksToList(blocks, true, false); close(); }, "1."));
    menu.appendChild(menuButton("Task List", function () { convertBlocksToList(blocks, false, true); close(); }, "☐"));
    menu.appendChild(menuButton("Remove List Style", function () {
      var lists = Array.from(new Set(blocks.map(function (block) {
        return block.tagName && block.tagName.toLowerCase() === "li" ? block.parentElement : null;
      }).filter(Boolean)));
      if (lists.length) {
        lists.forEach(unwrapList);
      } else {
        convertBlocksToParagraphs(blocks);
      }
      close();
    }, "⌫"));
  }

  function createMenu(x, y) {
    var menu = document.createElement("div");
    menu.dataset.lezinUi = "true";
    menu.className = "lezin-floating-menu";
    menu.style.left = Math.round(x) + "px";
    menu.style.top = Math.round(y) + "px";
    document.body.appendChild(menu);
    return menu;
  }

  /// Formatting styles active at the current selection, in the shared
  /// MarkdownFormatAction vocabulary. Used by the native context bar.
  function activeFormatStyles(node) {
    var styles = [];
    if (closestElement(node, "strong,b")) styles.push("bold");
    if (closestElement(node, "em,i")) styles.push("italic");
    if (closestElement(node, "del,s")) styles.push("strikethrough");
    if (closestElement(node, "code")) styles.push("code");
    if (closestElement(node, "h1")) styles.push("heading1");
    if (closestElement(node, "h2")) styles.push("heading2");
    if (closestElement(node, "h3")) styles.push("heading3");
    var li = closestElement(node, "li");
    if (li && li.parentElement) {
      styles.push(li.parentElement.tagName.toLowerCase() === "ol" ? "orderedList" : "bulletList");
    }
    if (closestElement(node, "blockquote")) styles.push("quote");
    return styles;
  }

  /// The selection context menu is native: report the selection's rect and
  /// active styles to Swift, which floats the shared formatting bar there.
  function showSelectionMenu() {
    var range = selectedTextRange();
    if (!range) {
      hideSelectionMenu();
      return;
    }
    var rect = range.getBoundingClientRect();
    var anchor = window.getSelection() && window.getSelection().anchorNode;
    notify("selectionContext", {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
      active: activeFormatStyles(anchor || range.commonAncestorContainer)
    });
  }

  function showBlockMenu(event) {
    var target = event.target;
    var block = closestElement(target, "h1,h2,h3,h4,h5,h6,p,li,pre code,table,td,th,strong,b,em,i,code,a,del,s,mark");

    event.preventDefault();
    event.stopPropagation();
    hideSelectionMenu();
    hideBlockMenu();
    if (!block) return false;

    blockMenu = createMenu(event.clientX, event.clientY);
    var inlineTarget = selectedInlineFormatOr(target);
    if (inlineTarget) {
      blockMenu.appendChild(menuButton("Plain Text", function () {
        var unwrapped = unwrapInlineFormat(inlineTarget);
        hideBlockMenu();
        return unwrapped;
      }, "T"));
      blockMenu.appendChild(menuSeparator());
    }
    addBlockConversionMenu(blockMenu, selectedBlocksOr(target));

    var code = closestElement(target, "pre code");
    if (code) {
      blockMenu.appendChild(menuSeparator());
      blockMenu.appendChild(menuButton("Exit Code Block", function () {
        var paragraph = createEditableParagraph();
        code.closest("pre").insertAdjacentElement("afterend", paragraph);
        focusTextOffset(paragraph, 0);
        setDirty(true);
        hideBlockMenu();
      }));
    }

    if (!blockMenu.children.length) hideBlockMenu();
    return true;
  }

  root.addEventListener("input", function () {
    if (suppressUndoCapture) {
      normalizePlainMarkdownBlocks();
      setDirty(true);
      return;
    }

    var beforeHTML = lastUndoHTML || root.innerHTML;
    suppressUndoCapture = true;
    normalizePlainMarkdownBlocks();
    suppressUndoCapture = false;

    if (!recordUndoChange(beforeHTML)) {
      setDirty(true);
    }
  });

  root.addEventListener("click", function (event) {
    hideBlockMenu();
    var image = event.target.closest("img");
    if (image && root.contains(image)) {
      event.preventDefault();
      selectImage(image);
      return;
    }

    clearSelectedImage();
  });

  root.addEventListener("contextmenu", function (event) {
    showBlockMenu(event);
  }, true);

  root.addEventListener("mouseup", function (event) {
    if (event.button !== 0) return;
    setTimeout(showSelectionMenu, 0);
  });

  function isImageRemovalKey(event) {
    return event.key === "Escape" || event.key === "Backspace" || event.key === "Delete";
  }

  document.addEventListener("keydown", function (event) {
    hideSelectionMenu();
    if (handleUndoShortcut(event)) return;
    if (withUndoAction(function () { return handleInlineShortcut(event); })) return;
    if (withUndoAction(function () { return handleCodeBlockExit(event); })) return;
    if (withUndoAction(function () { return handleCodeFenceShortcut(event); })) return;
    if (withUndoAction(function () { return handleMarkdownShortcut(event); })) return;
    if (withUndoAction(function () { return handleListItemEnter(event); })) return;

    if (!isImageRemovalKey(event)) return;
    if (!withUndoAction(removeSelectedImage)) return;

    event.preventDefault();
    event.stopPropagation();
  });

  root.addEventListener("paste", function (event) {
    event.preventDefault();
    var text = event.clipboardData ? event.clipboardData.getData("text/plain") : "";
    withUndoAction(function () {
      document.execCommand("insertText", false, text);
      setDirty(true);
      return true;
    });
  });

  document.addEventListener("copy", function (event) {
    if (!sourceMarkdown || !event.clipboardData || !selectionCoversRoot()) return;
    event.clipboardData.setData("text/plain", sourceMarkdown);
    event.preventDefault();
  });

  document.addEventListener("selectionchange", function () {
    notify("selectionChanged", getSelection() || {});
  });

  function internalHashTarget(link) {
    var rawHref = link.getAttribute("href") || "";
    var hash = "";
    if (rawHref.charAt(0) === "#") {
      hash = rawHref;
    } else {
      try {
        var url = new URL(link.href);
        if (url.origin !== window.location.origin || url.pathname !== window.location.pathname || !url.hash) return null;
        hash = url.hash;
      } catch (_) {
        return null;
      }
    }

    if (!hash || hash === "#") return null;
    var id = decodeURIComponent(hash.slice(1));
    return document.getElementById(id);
  }

  function activateInternalHashLink(link) {
    var target = internalHashTarget(link);
    if (!target) return false;
    target.scrollIntoView({ block: "start", behavior: "smooth" });
    if (window.history && typeof window.history.replaceState === "function") {
      window.history.replaceState(null, "", "#" + encodeURIComponent(target.id));
    }
    return true;
  }

  function fallbackCopyText(text) {
    return new Promise(function (resolve, reject) {
      var textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.top = "-1000px";
      textarea.style.left = "-1000px";
      document.body.appendChild(textarea);
      textarea.select();

      try {
        var copied = document.execCommand("copy");
        document.body.removeChild(textarea);
        copied ? resolve() : reject(new Error("Copy command failed"));
      } catch (error) {
        document.body.removeChild(textarea);
        reject(error);
      }
    });
  }

  function writeClipboardText(text) {
    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      return navigator.clipboard.writeText(text).catch(function () {
        return fallbackCopyText(text);
      });
    }
    return fallbackCopyText(text);
  }

  function codeCopyText(button) {
    var figure = button.closest("[data-nizel-code-copy]");
    if (!figure) return "";
    var source = figure.getAttribute("data-nizel-copy-source");
    if (source !== null) return source;
    var code = figure.querySelector("pre code, code");
    return code ? code.textContent : "";
  }

  function markCodeCopyButton(button, copied) {
    if (!button.dataset.lezinCopyLabel) {
      button.dataset.lezinCopyLabel = button.textContent || "Copy";
    }
    button.textContent = copied ? "Copied" : "Copy failed";
    button.dataset.lezinCopied = copied ? "true" : "false";
    window.setTimeout(function () {
      button.textContent = button.dataset.lezinCopyLabel || "Copy";
      delete button.dataset.lezinCopied;
    }, 1200);
  }

  function activateCodeCopyButton(button) {
    var text = codeCopyText(button);
    return writeClipboardText(text)
      .then(function () { markCodeCopyButton(button, true); })
      .catch(function () { markCodeCopyButton(button, false); });
  }

  document.addEventListener("click", function (event) {
    if (event.target.closest("input[data-nizel-task-checkbox][type='checkbox']")) {
      if (!isEditable) {
        event.preventDefault();
      }
      event.stopPropagation();
      return;
    }

    var copyButton = event.target.closest("[data-nizel-copy-button]");
    if (copyButton) {
      event.preventDefault();
      event.stopPropagation();
      activateCodeCopyButton(copyButton);
      return;
    }

    if (event.target.closest("img")) return;
    var link = event.target.closest("a[href]");
    if (!link) return;
    event.preventDefault();
    if (activateInternalHashLink(link)) return;
    notify("linkActivated", { url: link.href });
  });

  document.addEventListener("change", function (event) {
    var checkbox = event.target.closest("input[data-nizel-task-checkbox][type='checkbox']");
    if (!checkbox) return;
    if (!isEditable) {
      checkbox.checked = !checkbox.checked;
      syncTaskCheckboxAttribute(checkbox);
      return;
    }

    syncTaskCheckboxAttribute(checkbox);
    setDirty(true);
  });

  window.lezinBridge = {
    renderMarkdown: renderMarkdown,
    htmlToMarkdown: htmlToMarkdown,
    getCleanHtml: getCleanHtml,
    markClean: markClean,
    setEditable: setEditable,
    getSelection: getSelection,
    setScrollPosition: setScrollPosition,
    applyFormat: applyFormatCommand
  };

  notify("ready", {});
})();
