/**
 * Dark mode.
 *
 * Puts class "dark" on <html> when the system prefers a dark colour scheme,
 * or when the footer toggle has been used to choose one explicitly. The
 * colours live in style/dark.css. The toggle cycles auto -> dark -> light
 * and the choice persists in localStorage.
 *
 * Runs from <head> so the class is set before the page paints.
 */
(function () {
    'use strict';

    var STORAGE_KEY = 'transmission-theme'; // 'dark' | 'light' | absent for auto
    var LABELS = { auto: 'Theme: follows the system', dark: 'Theme: dark', light: 'Theme: light' };
    var GLYPHS = { auto: '◐', dark: '☾', light: '☀' }; // ◐ ☾ ☀
    var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;

    function stored() {
        try { return window.localStorage.getItem(STORAGE_KEY) || 'auto'; } catch (e) { return 'auto'; }
    }

    function store(mode) {
        try {
            if (mode === 'auto') { window.localStorage.removeItem(STORAGE_KEY); } else { window.localStorage.setItem(STORAGE_KEY, mode); }
        } catch (e) { /* ignore */ }
    }

    function isDark(mode) {
        if (mode === 'dark') { return true; }
        if (mode === 'light') { return false; }
        return !!(media && media.matches);
    }

    function apply() {
        var mode = stored();
        var root = document.documentElement;
        if (isDark(mode)) { root.className += (root.className ? ' ' : '') + 'dark'; }
        root.className = root.className.replace(/\bdark\b/g, isDark(mode) ? 'dark' : '').replace(/\s+/g, ' ').trim();
        var button = document.getElementById('theme-button');
        if (button) {
            button.textContent = GLYPHS[mode];
            button.title = LABELS[mode] + ' (click to change)';
        }
    }

    function cycle() {
        var next = { auto: 'dark', dark: 'light', light: 'auto' }[stored()] || 'auto';
        store(next);
        apply();
    }

    apply();
    if (media) {
        if (media.addEventListener) { media.addEventListener('change', apply); } else if (media.addListener) { media.addListener(apply); }
    }

    $(function () {
        var footer = $('div.torrent_footer');
        if (!footer.length) { return; }
        var button = document.createElement('div');
        button.id = 'theme-button';
        button.className = 'extra-footer-button';
        $(button).on('click', cycle);
        $('#compact-button').after(button);
        apply();
    });

    window.ExtraTheme = { mode: stored, cycle: cycle, isDark: function () { return isDark(stored()); } };
})();
