/* VocaMac site behaviour.
   Every feature here is an enhancement: the page is complete without it. */

(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  /* ---------- Sticky header hairline ---------- */

  var header = document.querySelector("[data-header]");

  if (header) {
    var setScrolled = function () {
      header.classList.toggle("is-scrolled", window.scrollY > 8);
    };

    setScrolled();
    window.addEventListener("scroll", setScrolled, { passive: true });
  }

  /* ---------- Mobile navigation ---------- */

  var toggle = document.querySelector("[data-nav-toggle]");
  var mobileNav = document.querySelector("[data-mobile-nav]");

  if (toggle && mobileNav) {
    var setOpen = function (open) {
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      mobileNav.hidden = !open;
    };

    setOpen(false);

    toggle.addEventListener("click", function () {
      setOpen(toggle.getAttribute("aria-expanded") !== "true");
    });

    mobileNav.addEventListener("click", function (event) {
      if (event.target.closest("a")) { setOpen(false); }
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && toggle.getAttribute("aria-expanded") === "true") {
        setOpen(false);
        toggle.focus();
      }
    });

    document.addEventListener("click", function (event) {
      if (toggle.getAttribute("aria-expanded") !== "true") { return; }
      if (toggle.contains(event.target) || mobileNav.contains(event.target)) { return; }
      setOpen(false);
    });

    window.addEventListener("resize", function () {
      if (window.innerWidth > 920) { setOpen(false); }
    });
  }

  /* ---------- Copy buttons ---------- */

  var canCopy = !!(navigator.clipboard && navigator.clipboard.writeText);

  document.querySelectorAll("[data-copy]").forEach(function (block) {
    var source = block.querySelector("code");
    if (!source || !canCopy) { return; }

    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy-btn";
    button.textContent = "Copy";
    button.setAttribute("aria-label", "Copy commands to clipboard");

    button.addEventListener("click", function () {
      // Drop the shell prompts so the paste is runnable.
      var text = Array.prototype.map
        .call(source.childNodes, function (node) {
          return node.classList && node.classList.contains("prompt") ? "" : node.textContent;
        })
        .join("")
        .trim();

      var restore = function () {
        button.textContent = "Copy";
        button.classList.remove("is-copied");
      };

      navigator.clipboard.writeText(text).then(
        function () {
          button.textContent = "Copied";
          button.classList.add("is-copied");
          setTimeout(restore, 2000);
        },
        function () {
          button.textContent = "Press ⌘C";
          setTimeout(restore, 2000);
        }
      );
    });

    block.appendChild(button);
  });

  /* ---------- Optional reveals ---------- */

  var revealItems = document.querySelectorAll(".reveal");

  if (revealItems.length) {
    var reveal = function (element) { element.classList.add("is-visible"); };

    if (reduceMotion.matches || !("IntersectionObserver" in window)) {
      revealItems.forEach(reveal);
    } else {
      document.documentElement.classList.add("js-reveal");

      var safetyNet;

      var observer = new IntersectionObserver(
        function (entries) {
          // The observer reports, so the blanket fallback is no longer needed:
          // without this, everything below the fold un-hid after 800ms and the
          // reveal never actually played on scroll.
          clearTimeout(safetyNet);
          entries.forEach(function (entry) {
            if (!entry.isIntersecting) { return; }
            reveal(entry.target);
            observer.unobserve(entry.target);
          });
        },
        { rootMargin: "0px 0px -8% 0px", threshold: 0.05 }
      );

      revealItems.forEach(function (element) { observer.observe(element); });

      // Safety net: never leave content hidden if the observer never fires.
      safetyNet = setTimeout(function () { revealItems.forEach(reveal); }, 800);
    }
  }

  /* ---------- Table of contents highlighting ---------- */

  var toc = document.querySelector("[data-toc]");

  if (toc && "IntersectionObserver" in window) {
    var tocLinks = {};
    var headings = [];

    toc.querySelectorAll('a[href^="#"]').forEach(function (link) {
      var heading = document.getElementById(decodeURIComponent(link.hash.slice(1)));
      if (!heading) { return; }
      tocLinks[heading.id] = link;
      headings.push(heading);
    });

    if (headings.length) {
      var current = null;

      var setCurrent = function (id) {
        if (id === current) { return; }
        if (current && tocLinks[current]) { tocLinks[current].classList.remove("is-current"); }
        current = id;
        if (current && tocLinks[current]) { tocLinks[current].classList.add("is-current"); }
      };

      var visible = {};

      var tocObserver = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (entry) {
            visible[entry.target.id] = entry.isIntersecting;
          });

          var first = headings.filter(function (heading) { return visible[heading.id]; })[0];
          if (first) { setCurrent(first.id); }
        },
        { rootMargin: "-12% 0px -70% 0px", threshold: 0 }
      );

      headings.forEach(function (heading) { tocObserver.observe(heading); });
      setCurrent(headings[0].id);
    }
  }

  /* ---------- FAQ convenience ---------- */

  var faq = document.querySelector("[data-faq]");

  if (faq) {
    faq.addEventListener("toggle", function (event) {
      var target = event.target;
      if (target.tagName !== "DETAILS" || !target.open) { return; }

      faq.querySelectorAll("details[open]").forEach(function (other) {
        if (other !== target) { other.open = false; }
      });
    }, true);
  }
})();
