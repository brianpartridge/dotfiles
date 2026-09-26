/**
 * Transfers indicator.
 *
 * Adds a small badge to each finished torrent showing how torrent-finished.rb
 * processed it: filed as TV or a movie, "other" when there was nothing to
 * file, "failed" when handling hit an error, and "not handled" when the
 * torrent completed recently but the script left no record at all.
 *
 * The data comes from /transfers/transfers.json, which the transfers
 * dashboard writes next to its page. Nothing upstream is modified: this file
 * wraps Transmission.prototype.refilter and appends one element per row.
 */
(function () {
    'use strict';

    var DATA_URL = '/transfers/transfers.json';
    var REFRESH_MS = 60 * 1000;
    var DAY = 24 * 60 * 60;

    var LABELS = {
        tv: 'TV',
        movie: 'Movie',
        other: 'Other',
        error: 'Failed',
        unhandled: 'Not handled'
    };

    var data = null;
    var loaded = false;

    // The stock UI only fetches hashString for the inspector and never asks
    // for doneDate. Add hashString to the fields fetched when a torrent first
    // appears, and doneDate to the per-refresh fields so it stays current for
    // torrents that finish while the page is open.
    function addField(list, field) {
        if (list && list.indexOf(field) === -1) { list.push(field); }
    }
    if (window.Torrent && Torrent.Fields) {
        addField(Torrent.Fields.Metadata, 'hashString');
        addField(Torrent.Fields.Stats, 'doneDate');
    }

    function load() {
        $.ajax({
            url: DATA_URL,
            dataType: 'json',
            cache: false,
            success: function (d) { data = d; loaded = true; sync(); },
            error: function () { data = null; loaded = true; sync(); }
        });
    }

    function recordFor(torrent) {
        if (!data) { return null; }
        var hash = (torrent.getHashString() || '').toLowerCase();
        if (data.by_hash && data.by_hash[hash]) { return data.by_hash[hash]; }
        if (data.by_name && data.by_name[torrent.getName()]) { return data.by_name[torrent.getName()]; }
        return null;
    }

    // What to show for a torrent, or null for nothing.
    function classify(torrent, now) {
        var record = recordFor(torrent);
        if (record) {
            var status = record.status === 'warning' ? 'other' : record.status;
            var kind = status === 'ok' ? record.outcome : status;
            var title = record.message || '';
            if (record.destination) { title += '\n' + record.destination; }
            return { kind: kind, text: LABELS[kind] || kind, title: title };
        }
        if (!data || torrent.getPercentDone() < 1) { return null; }
        var windowDays = data.unhandled_window_days || 7;
        var doneAt = torrent.fields.doneDate || now; // completed since the page loaded
        if (now - doneAt > windowDays * DAY) { return null; }
        return {
            kind: 'unhandled',
            text: LABELS.unhandled,
            title: 'Finished, but torrent-finished.sh left no record. Check ~/logs/torrent-finished.out.'
        };
    }

    function badgeFor(element) {
        var badge = element._transfer_badge;
        if (!badge) {
            badge = document.createElement('a');
            badge.className = 'transfer_badge';
            badge.target = '_blank';
            badge.rel = 'noopener';
            // Keep the click from selecting or toggling the row underneath.
            $(badge).on('click dblclick mousedown', function (e) { e.stopPropagation(); });
            element.appendChild(badge);
            element._transfer_badge = badge;
        }
        return badge;
    }

    function sync() {
        var tr = window.transmission;
        if (!loaded || !tr || !tr._rows) { return; }
        var now = Math.floor(Date.now() / 1000);
        for (var i = 0, row; (row = tr._rows[i]); ++i) {
            var element = row.getElement();
            var info = classify(row.getTorrent(), now);
            if (!info) {
                if (element._transfer_badge) { element._transfer_badge.style.display = 'none'; }
                continue;
            }
            var badge = badgeFor(element);
            badge.style.display = '';
            badge.className = 'transfer_badge ' + info.kind;
            badge.textContent = info.text;
            badge.title = info.title;
            badge.href = (data && data.dashboard_url) || '/transfers/';
        }
    }

    // Re-badge whenever the list is rebuilt or refiltered.
    if (window.Transmission && Transmission.prototype.refilter) {
        var refilter = Transmission.prototype.refilter;
        Transmission.prototype.refilter = function () {
            var result = refilter.apply(this, arguments);
            sync();
            return result;
        };
    }

    $(function () {
        load();
        setInterval(load, REFRESH_MS);
        setInterval(sync, 5000); // catches rows updated in place between refilters
    });
})();
