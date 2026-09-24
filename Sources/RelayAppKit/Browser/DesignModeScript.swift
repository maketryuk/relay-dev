import Foundation

/// What design mode runs inside the page.
///
/// A script rather than native hit-testing, because the things worth handing
/// an agent — which element it is, what it is called in the DOM, which
/// component rendered it, what it computes to — only exist in the page. It runs
/// in the page's own world, not an isolated one: React, Vue and Svelte leave
/// what rendered an element as properties on the element, and those are
/// invisible from a separate world.
///
/// The page can see and tamper with it, so nothing it returns is trusted:
/// `DesignPick` clamps every field again on the way in. What it guards against
/// on its own account is leaking — query strings, tokens and passwords are
/// dropped before anything leaves the page.
///
/// The component and source lookup covers React through 19, Vue and
/// Svelte.
enum DesignModeScript {
    /// Installs the overlay and `window.__relayDesign`, replacing any earlier
    /// copy. Evaluates to `true`.
    static let arm = #"""
    (() => {
      'use strict';
      // Whatever sits here — an older copy, or something the page put there to
      // be called instead — is taken down before this one is installed.
      const previous = window.__relayDesign;
      if (previous && typeof previous.teardown === 'function') {
        try { previous.teardown(); } catch (error) {}
      }
      try { delete window.__relayDesign; } catch (error) {}

      const LIMITS = {
        text: 200, html: 3000, attribute: 200, selector: 700, path: 900,
        classes: 400, nearby: 8, nearbyText: 120, ancestors: 10,
        components: 6, source: 500, textNodes: 120
      };
      const SAFE_ATTRIBUTES = new Set([
        'id', 'class', 'name', 'type', 'role', 'href', 'src', 'alt', 'title',
        'placeholder', 'for', 'action', 'method'
      ]);
      const SECRET = /access_token|auth_token|api_key|apikey|client_secret|oauth_state|x-amz-|session_id|sessionid|csrf|secret|password|passwd/i;
      const STYLES = [
        'display', 'position', 'width', 'height', 'margin', 'padding', 'gap',
        'color', 'background-color', 'border', 'border-radius', 'box-shadow',
        'font-family', 'font-size', 'font-weight', 'line-height', 'text-align',
        'opacity', 'z-index'
      ];

      const clamp = (value, limit) => {
        const text = typeof value === 'string' ? value : '';
        return text.length <= limit ? text : text.slice(0, limit) + '…';
      };
      const collapse = (text) => text.replace(/\s+/g, ' ').trim();
      const isSecret = (value) => typeof value === 'string' && SECRET.test(value);

      const cleanURL = (value) => {
        try {
          const url = new URL(value, location.href);
          if (!['http:', 'https:', 'file:'].includes(url.protocol)) return '';
          url.search = '';
          url.hash = '';
          return url.toString();
        } catch (error) {
          return '';
        }
      };

      // Bounded twice over: a page's text can be a novel, and all that is
      // wanted is enough of it to say which element this is.
      const textOf = (element, limit) => {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let text = '';
        let visited = 0;
        let node;
        while ((node = walker.nextNode()) && text.length < limit * 2 && visited < LIMITS.textNodes) {
          visited += 1;
          const parent = node.parentElement;
          if (parent && (parent.closest('script, style, noscript'))) continue;
          text += ' ' + (node.nodeValue || '').slice(0, limit * 2);
        }
        return clamp(collapse(text), limit);
      };

      const escapeCSS = (value) => (window.CSS && CSS.escape) ? CSS.escape(value)
        : String(value).replace(/[^a-zA-Z0-9_-]/g, (character) => '\\' + character);

      // Generated class names change on every build and say nothing to a
      // person reading the selector later.
      const looksGenerated = (name) =>
        /^css-[a-z0-9]+$/i.test(name) ||
        (/^[A-Za-z0-9_-]{12,}$/.test(name) && /\d/.test(name) && /[A-Z]/.test(name));

      const stableClasses = (element, count) => {
        const result = [];
        for (const name of element.classList || []) {
          if (result.length >= count) break;
          if (!name || name.length > 60 || isSecret(name) || looksGenerated(name)) continue;
          result.push(name);
        }
        return result;
      };

      const selectorPart = (element) => {
        const tag = element.tagName.toLowerCase();
        if (element.id && !isSecret(element.id)) return tag + '#' + escapeCSS(element.id);
        return tag + stableClasses(element, 2).map((name) => '.' + escapeCSS(name)).join('');
      };

      const isUnique = (selector) => {
        try { return document.querySelectorAll(selector).length === 1; } catch (error) { return false; }
      };

      const nthOfType = (element) => {
        let index = 1;
        for (let sibling = element.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
          if (sibling.tagName === element.tagName) index += 1;
        }
        if (index > 1) return ':nth-of-type(' + index + ')';
        for (let sibling = element.nextElementSibling; sibling; sibling = sibling.nextElementSibling) {
          if (sibling.tagName === element.tagName) return ':nth-of-type(1)';
        }
        return '';
      };

      // The shortest chain from the element upwards that names only it.
      const selectorFor = (element) => {
        const parts = [];
        for (let current = element; current && current.nodeType === 1 && current !== document.body && parts.length < 10; current = current.parentElement) {
          let part = selectorPart(current);
          if (!isUnique([part].concat(parts).join(' > '))) part += nthOfType(current);
          parts.unshift(part);
          const selector = parts.join(' > ');
          if (isUnique(selector)) return clamp(selector, LIMITS.selector);
        }
        return clamp(parts.join(' > ') || element.tagName.toLowerCase(), LIMITS.selector);
      };

      // Where it is, the way a person would say it: the landmarks rather than
      // every div on the way.
      const readablePath = (element) => {
        const parts = [];
        for (let current = element; current && current !== document.body && current !== document.documentElement && parts.length < 6; current = current.parentElement) {
          const tag = current.tagName.toLowerCase();
          const label = current.getAttribute('aria-label');
          const role = current.getAttribute('role');
          const classes = stableClasses(current, 1);
          if (current.id && !isSecret(current.id)) parts.unshift('#' + escapeCSS(current.id));
          else if (label && !isSecret(label)) parts.unshift(tag + '[aria-label="' + clamp(label, 40).replace(/"/g, '\\"') + '"]');
          else if (role) parts.unshift(tag + '[role="' + clamp(role, 30) + '"]');
          else if (classes.length) parts.unshift(tag + '.' + escapeCSS(classes[0]));
          else parts.unshift(tag);
        }
        return clamp(parts.join(' > '), LIMITS.path);
      };

      const attributesOf = (element) => {
        const result = {};
        for (const attribute of element.attributes) {
          const name = attribute.name.toLowerCase();
          if (!SAFE_ATTRIBUTES.has(name) && !name.startsWith('aria-') && !name.startsWith('data-test')) continue;
          const value = attribute.value;
          if (isSecret(value)) result[name] = '[redacted]';
          else if (name === 'href' || name === 'src' || name === 'action') result[name] = cleanURL(value);
          else result[name] = clamp(value, LIMITS.attribute);
        }
        return result;
      };

      // The markup as it stands, less what is noise to a reader or dangerous
      // to hand on: scripts, styles, secrets, a password's value, and the long
      // tail of an inline SVG path or a data URL.
      const htmlOf = (element) => {
        const copy = element.cloneNode(true);
        for (const noise of copy.querySelectorAll('script, style, noscript')) noise.remove();
        for (const node of [copy].concat(Array.from(copy.querySelectorAll('*')))) {
          for (const attribute of Array.from(node.attributes || [])) {
            const name = attribute.name.toLowerCase();
            if (isSecret(name) || isSecret(attribute.value) || name.startsWith('on')) node.removeAttribute(attribute.name);
            else if (name === 'value' && (node.getAttribute('type') || '').toLowerCase() === 'password') node.removeAttribute(attribute.name);
            else if ((name === 'href' || name === 'src' || name === 'action') && attribute.value) node.setAttribute(attribute.name, cleanURL(attribute.value));
            else if (attribute.value.length > LIMITS.attribute) node.setAttribute(attribute.name, attribute.value.slice(0, LIMITS.attribute) + '…');
          }
        }
        return clamp(copy.outerHTML || '', LIMITS.html);
      };

      const accessibleName = (element) => {
        const label = element.getAttribute('aria-label');
        if (label) return clamp(label, 120);
        const labelledBy = element.getAttribute('aria-labelledby');
        if (labelledBy) {
          const names = labelledBy.split(/\s+/).slice(0, 8)
            .map((id) => document.getElementById(id)).filter(Boolean)
            .map((node) => textOf(node, 80));
          if (names.length) return clamp(names.join(' '), 120);
        }
        const tag = element.tagName.toLowerCase();
        if (tag === 'img') return clamp(element.getAttribute('alt') || '', 120);
        if (tag === 'input' || tag === 'textarea') {
          const labelElement = element.id ? document.querySelector('label[for="' + escapeCSS(element.id) + '"]') : null;
          return clamp(labelElement ? textOf(labelElement, 80) : (element.getAttribute('placeholder') || ''), 120);
        }
        if (['button', 'a', 'label', 'summary', 'option'].includes(tag)) return textOf(element, 120);
        return clamp(element.getAttribute('title') || '', 120);
      };

      const stylesOf = (element) => {
        const computed = getComputedStyle(element);
        const result = {};
        for (const property of STYLES) result[property] = clamp(computed.getPropertyValue(property), 200);
        return result;
      };

      const nearbyText = (element) => {
        const result = [];
        let before = element.previousElementSibling;
        let after = element.nextElementSibling;
        let visited = 0;
        while ((before || after) && result.length < LIMITS.nearby && visited < 60) {
          for (const sibling of [before, after]) {
            if (!sibling || result.length >= LIMITS.nearby) continue;
            visited += 1;
            const text = textOf(sibling, LIMITS.nearbyText);
            if (text) result.push(sibling.tagName.toLowerCase() + ': ' + text);
          }
          before = before && before.previousElementSibling;
          after = after && after.nextElementSibling;
        }
        return result;
      };

      const ancestorsOf = (element) => {
        const result = [];
        for (let current = element.parentElement; current && current !== document.documentElement && result.length < LIMITS.ancestors; current = current.parentElement) {
          const role = current.getAttribute('role');
          result.push(current.tagName.toLowerCase() + (role ? '[role=' + clamp(role, 30) + ']' : ''));
        }
        return result;
      };

      // MARK: Which component, and where it is written

      const cleanSourcePath = (path) => String(path || '')
        .replace(/[?#].*$/, '')
        .replace(/^webpack-internal:\/\/\/(\([^)]*\)\/)?\.?\/?/, '')
        .replace(/^(webpack|turbopack|rsc):\/\/\/?(\[project\]\/)?\.?\/?/, '')
        .replace(/^https?:\/\/[^/]+(\/@fs)?/, '')
        .replace(/^file:\/\//, '')
        .replace(/^\/(src|app|pages|components|lib)\//, '$1/');

      const fiberOf = (element) => {
        for (const key of Object.keys(element)) {
          if (key.startsWith('__reactFiber$') || key.startsWith('__reactInternalInstance$')) {
            try { return element[key] || null; } catch (error) { return null; }
          }
        }
        return null;
      };

      const componentName = (type) => {
        if (!type || typeof type === 'string') return null;
        return type.displayName || type.name
          || (type.render && (type.render.displayName || type.render.name))
          || (type.type && (type.type.displayName || type.type.name)) || null;
      };

      // Routers, providers and boundaries are how an app is wired, not what a
      // person points at.
      const isPlumbing = (name) => !name || name.length <= 2 ||
        /^(Fragment|Root|Routes|Route|Outlet|Provider|Consumer|Profiler|Suspense|StrictMode)$/.test(name) ||
        /(Boundary|BoundaryHandler|Router|Provider|Consumer|Context|Wrapper)$/.test(name) ||
        /^(Inner|Outer|Client|Server|RSC|Dev|React|Hot)/.test(name);

      // React 19 keeps no file name; it keeps the stack of the call that made
      // the element. The first frame outside React is the line that wrote it,
      // as the dev server serves it — which is usually the source file, with
      // lines that transpiling may have moved.
      const sourceFromStack = (stack) => {
        for (const line of String(stack || '').split('\n').slice(1, 30)) {
          if (/node_modules|react-dom|jsx-dev-runtime|jsx-runtime|react-stack|__relayDesign/.test(line)) continue;
          const match = line.match(/\(?((?:https?|file|webpack-internal|webpack|turbopack|rsc):\/\/[^\s)]+?):(\d+):(\d+)\)?\s*$/);
          if (!match) continue;
          const file = cleanSourcePath(match[1]);
          if (!file || /\/_next\/static\/|\/chunks\/|\.bundle\.js$/.test(file)) continue;
          return { file: file, line: Number(match[2]), column: Number(match[3]), exact: false };
        }
        return null;
      };

      const fromReact = (element) => {
        let fiber = fiberOf(element);
        if (!fiber) return null;
        const components = [];
        let source = null;
        for (let depth = 0; fiber && depth < 40; depth += 1, fiber = fiber.return) {
          const name = componentName(fiber.type || fiber.elementType);
          if (name && !isPlumbing(name) && !components.includes(name) && components.length < LIMITS.components) components.push(name);
          if (!source) {
            const debug = fiber._debugSource || (fiber._debugOwner && fiber._debugOwner._debugSource);
            if (debug && debug.fileName && debug.lineNumber) {
              source = { file: cleanSourcePath(debug.fileName), line: debug.lineNumber, column: debug.columnNumber || null, exact: true };
            } else if (fiber._debugStack) {
              try { source = sourceFromStack(fiber._debugStack.stack); } catch (error) {}
            }
          }
        }
        return { framework: 'React', components: components.reverse(), source: source };
      };

      const fromVue = (element) => {
        for (let current = element; current; current = current.parentElement) {
          let instance = current.__vueParentComponent;
          if (instance) {
            const components = [];
            let file = null;
            for (let depth = 0; instance && depth < 20; depth += 1, instance = instance.parent) {
              const type = instance.type || {};
              const name = type.name || type.__name || (type.__file ? type.__file.split('/').pop().replace(/\.vue$/, '') : null);
              if (name && !isPlumbing(name) && !components.includes(name) && components.length < LIMITS.components) components.push(name);
              if (!file && type.__file) file = cleanSourcePath(type.__file);
            }
            return { framework: 'Vue', components: components.reverse(), source: file ? { file: file, line: null, column: null, exact: true } : null };
          }
          const legacy = current.__vue__;
          if (legacy && legacy.$options) {
            const file = legacy.$options.__file;
            return {
              framework: 'Vue',
              components: legacy.$options.name ? [legacy.$options.name] : [],
              source: file ? { file: cleanSourcePath(file), line: null, column: null, exact: true } : null
            };
          }
        }
        return null;
      };

      const fromSvelte = (element) => {
        for (let current = element; current; current = current.parentElement) {
          const meta = current.__svelte_meta;
          if (meta && meta.loc && meta.loc.file) {
            const file = cleanSourcePath(meta.loc.file);
            const name = file.split('/').pop().replace(/\.svelte$/, '');
            // Svelte counts lines from zero.
            return { framework: 'Svelte', components: [name], source: { file: file, line: meta.loc.line + 1, column: meta.loc.column + 1, exact: true } };
          }
        }
        return null;
      };

      const fromAngular = (element) => {
        const ng = window.ng;
        if (!ng || typeof ng.getOwningComponent !== 'function') return null;
        try {
          const component = ng.getComponent(element) || ng.getOwningComponent(element);
          const name = component && component.constructor && component.constructor.name;
          return name ? { framework: 'Angular', components: [name], source: null } : null;
        } catch (error) {
          return null;
        }
      };

      const originOf = (element) => {
        for (const read of [fromReact, fromVue, fromSvelte, fromAngular]) {
          try {
            const found = read(element);
            if (found && (found.components.length || found.source)) {
              if (found.source && (isSecret(found.source.file) || !found.source.file)) found.source = null;
              if (found.source) found.source.file = clamp(found.source.file, LIMITS.source);
              return found;
            }
          } catch (error) {}
        }
        return null;
      };

      const describe = (element) => {
        const rect = element.getBoundingClientRect();
        const origin = originOf(element);
        return {
          page: {
            url: cleanURL(location.href),
            title: clamp(document.title || '', 200),
            viewport: { width: innerWidth, height: innerHeight },
            scroll: { x: scrollX, y: scrollY },
            devicePixelRatio: devicePixelRatio || 1
          },
          element: {
            tag: element.tagName.toLowerCase(),
            selector: selectorFor(element),
            path: readablePath(element),
            classes: isSecret(element.getAttribute('class') || '') ? '[redacted]' : clamp(element.getAttribute('class') || '', LIMITS.classes),
            text: textOf(element, LIMITS.text),
            html: htmlOf(element),
            attributes: attributesOf(element),
            role: element.getAttribute('role') || null,
            name: accessibleName(element) || null,
            rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
            styles: stylesOf(element),
            framework: origin ? origin.framework : null,
            components: origin ? origin.components : [],
            source: origin ? origin.source : null
          },
          nearby: nearbyText(element),
          ancestors: ancestorsOf(element)
        };
      };

      // MARK: The overlay

      // Its own shadow root, closed, so the page's styles cannot reach it and
      // its script cannot find it with a selector.
      const host = document.createElement('div');
      host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;cursor:crosshair;pointer-events:auto;';
      const shadow = host.attachShadow({ mode: 'closed' });
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;display:none;pointer-events:none;box-sizing:border-box;border:2px solid #4C8DFF;border-radius:3px;background:rgba(76,141,255,0.12);box-shadow:0 0 0 1px rgba(0,0,0,0.35);';
      const label = document.createElement('div');
      label.style.cssText = 'position:fixed;display:none;pointer-events:none;max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding:3px 7px;border-radius:4px;background:rgba(18,19,22,0.94);color:#E6E7EA;font:11px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;box-shadow:0 2px 8px rgba(0,0,0,0.35);';
      shadow.append(box, label);
      document.documentElement.appendChild(host);

      let current = null;
      let frozen = false;
      let settle = null;

      const place = () => {
        if (!current || !current.isConnected) {
          box.style.display = 'none';
          label.style.display = 'none';
          return;
        }
        const rect = current.getBoundingClientRect();
        Object.assign(box.style, { display: 'block', left: rect.x + 'px', top: rect.y + 'px', width: rect.width + 'px', height: rect.height + 'px' });
        const origin = originOf(current);
        const component = origin && origin.components.length ? '<' + origin.components[origin.components.length - 1] + '>  ' : '';
        const text = textOf(current, 32);
        label.textContent = component + current.tagName.toLowerCase() + (text ? '  "' + text + '"' : '') + '  ' + Math.round(rect.width) + '×' + Math.round(rect.height);
        const top = rect.bottom + 6 + 24 > innerHeight ? Math.max(4, rect.top - 28) : rect.bottom + 6;
        Object.assign(label.style, { display: 'block', left: Math.max(4, Math.min(rect.x, innerWidth - 200)) + 'px', top: top + 'px' });
      };

      const elementAt = (x, y) => {
        host.style.pointerEvents = 'none';
        const found = document.elementFromPoint(x, y);
        host.style.pointerEvents = frozen ? 'none' : 'auto';
        return found && found !== document.documentElement && found !== document.body ? found : null;
      };

      const onMove = (event) => {
        if (frozen) return;
        const found = elementAt(event.clientX, event.clientY);
        if (found === current) return;
        current = found;
        requestAnimationFrame(place);
      };

      const finish = (value) => {
        const resolve = settle;
        settle = null;
        if (resolve) resolve(value);
      };

      const onClick = (event) => {
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
        if (frozen || !current) return;
        let described;
        try { described = describe(current); } catch (error) { described = { failed: String(error && error.message || error) }; }
        frozen = true;
        host.style.pointerEvents = 'none';
        host.style.cursor = 'default';
        finish(described);
      };

      const onKey = (event) => {
        if (event.key !== 'Escape') return;
        event.preventDefault();
        event.stopPropagation();
        finish({ cancelled: 'escape' });
      };

      const onScroll = () => requestAnimationFrame(place);

      host.addEventListener('mousemove', onMove, true);
      host.addEventListener('click', onClick, true);
      host.addEventListener('contextmenu', onClick, true);
      window.addEventListener('keydown', onKey, true);
      window.addEventListener('scroll', onScroll, true);
      window.addEventListener('resize', onScroll, true);

      window.__relayDesign = {
        // An async function, so what comes back is the engine's own promise
        // even on a page that has replaced `Promise` — which Angular's zone
        // does, and whose promises the DevTools protocol does not wait for.
        pick: async function () {
          finish({ cancelled: 'superseded' });
          return await new Promise((resolve) => { settle = resolve; });
        },
        // After a pick the element stays outlined while Relay asks what to do
        // with it; this lets the pointer choose again.
        resume: function () {
          frozen = false;
          host.style.pointerEvents = 'auto';
          host.style.cursor = 'crosshair';
          return true;
        },
        hide: function () { host.style.visibility = 'hidden'; return true; },
        show: function () { host.style.visibility = 'visible'; return true; },
        teardown: function () {
          finish({ cancelled: 'teardown' });
          host.removeEventListener('mousemove', onMove, true);
          host.removeEventListener('click', onClick, true);
          host.removeEventListener('contextmenu', onClick, true);
          window.removeEventListener('keydown', onKey, true);
          window.removeEventListener('scroll', onScroll, true);
          window.removeEventListener('resize', onScroll, true);
          host.remove();
          try { delete window.__relayDesign; } catch (error) {}
          return true;
        }
      };
      return true;
    })()
    """#

    /// Waits for the next click, and evaluates to what was picked, or to an
    /// object with `cancelled` saying why nothing was.
    static let pick = "window.__relayDesign ? window.__relayDesign.pick() : ({ cancelled: 'gone' })"

    static let resume = "window.__relayDesign ? window.__relayDesign.resume() : false"
    static let hide = "window.__relayDesign ? window.__relayDesign.hide() : false"
    static let show = "window.__relayDesign ? window.__relayDesign.show() : false"
    static let teardown = "window.__relayDesign ? window.__relayDesign.teardown() : true"
}
