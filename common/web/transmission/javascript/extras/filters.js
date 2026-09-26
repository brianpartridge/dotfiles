/**
 * Extra filters: handling result and age.
 *
 * Adds two selects to the filter bar next to Transmission's own "Show" and
 * tracker filters. They narrow the list on top of whatever those select, by
 * wrapping Torrent.prototype.test, so the transfer count and every other
 * behaviour of the stock filtering stay as they are. Choices persist in
 * localStorage. Handling values come from transfers.js.
 */
(function () {
    'use strict';

    var DAY = 24 * 60 * 60;
    var STORAGE_KEY = 'transmission-extra-filters';

    var HANDLING = [
        ['any', 'Any handling'],
        ['filed', 'Filed'],
        ['tv', 'Filed: TV'],
        ['movie', 'Filed: Movie'],
        ['other', 'Other'],
        ['error', 'Failed'],
        ['unhandled', 'Not handled'],
        ['norecord', 'No record']
    ];

    var AGE = [
        ['any', 'Any age'],
        ['added-1d', 'Added today'],
        ['added-7d', 'Added this week'],
        ['added-30d', 'Added this month'],
        ['added-30d+', 'Added over a month ago'],
        ['done-7d+', 'Finished over a week ago'],
        ['done-30d+', 'Finished over a month ago']
    ];

    var current = { handling: 'any', age: 'any' };

    function loadChoices() {
        try {
            var saved = JSON.parse(window.localStorage.getItem(STORAGE_KEY) || '{}');
            if (saved.handling) { current.handling = saved.handling; }
            if (saved.age) { current.age = saved.age; }
        } catch (e) { /* private mode or no storage: defaults are fine */ }
    }

    function saveChoices() {
        try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(current)); } catch (e) { /* ignore */ }
    }

    function passesHandling(torrent) {
        if (current.handling === 'any') { return true; }
        var extra = window.TransfersExtra;
        if (!extra || !extra.isLoaded()) { return true; } // no data yet: show everything rather than nothing
        if (current.handling === 'norecord') { return !extra.hasRecord(torrent); }
        var info = extra.classify(torrent);
        var kind = info ? info.kind : null;
        if (current.handling === 'filed') { return kind === 'tv' || kind === 'movie'; }
        return kind === current.handling;
    }

    function passesAge(torrent, now) {
        if (current.age === 'any') { return true; }
        var added = torrent.getDateAdded() || 0;
        var done = torrent.fields.doneDate || 0;
        switch (current.age) {
            case 'added-1d': return now - added <= DAY;
            case 'added-7d': return now - added <= 7 * DAY;
            case 'added-30d': return now - added <= 30 * DAY;
            case 'added-30d+': return now - added > 30 * DAY;
            case 'done-7d+': return done > 0 && now - done > 7 * DAY;
            case 'done-30d+': return done > 0 && now - done > 30 * DAY;
            default: return true;
        }
    }

    function passes(torrent) {
        var now = Math.floor(Date.now() / 1000);
        return passesHandling(torrent) && passesAge(torrent, now);
    }

    if (window.Torrent && Torrent.prototype.test) {
        var test = Torrent.prototype.test;
        Torrent.prototype.test = function () {
            return test.apply(this, arguments) && passes(this);
        };
    }

    function buildSelect(id, options, value) {
        var select = document.createElement('select');
        select.id = id;
        select.className = 'extra-filter';
        for (var i = 0; i < options.length; ++i) {
            var option = document.createElement('option');
            option.value = options[i][0];
            option.textContent = options[i][1];
            select.appendChild(option);
        }
        select.value = value;
        return select;
    }

    function refilter() {
        if (window.transmission && transmission.refilter) { transmission.refilter(true); }
    }

    $(function () {
        loadChoices();
        var anchor = $('#filter-tracker');
        if (!anchor.length) { return; }
        var handling = buildSelect('filter-handling', HANDLING, current.handling);
        var age = buildSelect('filter-age', AGE, current.age);
        // Grouped so the stylesheet can drop both onto their own line on phones.
        var group = document.createElement('span');
        group.id = 'extra-filters';
        group.appendChild(handling);
        group.appendChild(age);
        anchor.after(group);
        $(handling).on('change', function () { current.handling = this.value; saveChoices(); refilter(); });
        $(age).on('change', function () { current.age = this.value; saveChoices(); refilter(); });
        // Handling data arrives after the first render; re-run an active filter when it does.
        $(document).on('transfers:updated', function () { if (current.handling !== 'any') { refilter(); } });
        if (current.handling !== 'any' || current.age !== 'any') { refilter(); }
    });

    window.ExtraFilters = { current: current, passes: passes };
})();
