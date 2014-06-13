var Analyzer = (function() {
  var loadCharts = function(boardId) {
    loadWipChart(boardId);
    loadCfdChart(boardId);
    loadStats(boardId);
    loadLabelCount(boardId);
  }

  var loadWipChart = function(boardId) {
    $.get("/boards/" + boardId + "/data", function(data) {
      $('#wip-spinner').hide();
      var theData = jQuery.parseJSON(data);
      var wip_data = new wipChartData();
      wip_data.lists = theData.wipcategories;
      wip_data.counts = [{
        name: "Cards in List",
        showInLegend: false,
        data: theData.wipdata
      }];
      var wc = new wipChart(wip_data);
      wc.buildChart();
    });
  }

  var loadCfdChart = function(boardId) {
    $.get("/boards/" + boardId + "/cfd", function(data) {
      $('#cfd-spinner').hide();

      var theData = jQuery.parseJSON(data);
      var cfdData = new cfdChartData();
      var cc = new cfdChart({
        data: theData.cfddata,
        dates: theData.dates,
        boardName: "Ollert"
      });
      cc.buildChart();
    });
  }

  var loadStats = function(boardId) {
    $.get("/boards/" + boardId + "/stats", function(data) {
      $.each($('.stats-spinner'), function(i, item) {
        $(item).hide();
      });

      var theData = jQuery.parseJSON(data);
      $('#avg_members_per_card').text(theData.avg_members_per_card);
      $('#avg_cards_per_member').text(theData.avg_cards_per_member);
      $('#list_with_most_cards_name').text(theData.list_with_most_cards_name);
      $('#list_with_most_cards_count').text(theData.list_with_most_cards_count);
      $('#list_with_least_cards_name').text(theData.list_with_least_cards_name);
      $('#list_with_least_cards_count').text(theData.list_with_least_cards_count);
      $('#board_members_count').text(theData.board_members_count);
      $('#card_count').text(theData.card_count);
      $('#oldest_card_name').text(theData.oldest_card_name);
      $('#oldest_card_age').text(theData.oldest_card_age);
      $('#newest_card_name').text(theData.newest_card_name);
      $('#newest_card_age').text(theData.newest_card_age);
    });
  }

  var loadLabelCount = function(boardId) {
    $.get("/boards/" + boardId + "/labelcounts", function(data) {
      $('#label-count-spinner').hide();

      var theData = jQuery.parseJSON(data);

      var lb_data = new labelCountChartData();
      lb_data.labels = theData.labels;
      lb_data.counts = theData.counts;
      lb_data.colors = theData.colors;
      var labelCount = new labelCountChart(lb_data);
      labelCount.buildChart();
    });
  }

  return {
    loadCharts: loadCharts
  }
}());