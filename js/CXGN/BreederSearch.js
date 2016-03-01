window.onload = function initialize() {

    jQuery('#select1').change( // reset start from list if select1 changes
	function() {
	    var startlist = jQuery('#c1_data_list_select').val();
	    if (startlist) {
		create_list_start('Start from a list');
	    }
	});

    jQuery('#select1, #select2, #select3, #select4').change(  // retrieve new data once new category is selected
    	function() {
	    var this_section = jQuery(this).attr('name');
	    reset_downstream_sections(this_section);
	    update_select_categories(this_section);
	    var category = jQuery(this).val();

	    if (!category) { // reset by returning empty if no category was defined
		var data_element = "c"+this_section+"_data";
		jQuery("#"+data_element).html('');
		return;
	    }
	    var categories = get_selected_categories(this_section);
	    var data = ''
	    if (this_section !== "1") data = get_selected_data(this_section);
	    var error = check_missing_criteria(categories, data, this_section); // make sure criteria selected in each panel
	    if (error) return;
	    if (data.length >= categories.length) data.pop(); //remove extra data array if exists

	    retrieve_and_display_set(categories, data, this_section);
	    update_download_options(this_section);
	});

    jQuery('#c1_data, #c2_data, #c3_data, #c4_data').change( // update wizard panels and categories when data selections change
    	function() {
	    var this_section = jQuery(this).attr('name');

	    var data_id = jQuery(this).attr('id');
	    var data = jQuery('#'+data_id).val() || [];;
	    var count_id = "c"+this_section+"_data_count";

	    reset_downstream_sections(this_section);
	    update_select_categories(this_section);
	    show_list_counts(count_id, jQuery('#'+data_id).text().split("\n").length-1, data.length);
	    update_download_options(this_section);
	});

    jQuery('#c1_select_all, #c2_select_all, #c3_select_all, #c4_select_all').click( // select all data in a wizard panel
    	function() {
	    var this_section = jQuery(this).attr('name');
	    var data_id = "c"+this_section+"_data";
	    selectAllOptions(document.getElementById(data_id));

	    var data = jQuery("#"+data_id).val() || [];;
	    var count_id = "c"+this_section+"_data_count";

	    show_list_counts(count_id, jQuery('#'+data_id).text().split("\n").length-1, data.length);
	    update_select_categories(this_section);
	    update_download_options(this_section);
	});

      jQuery('select').dblclick(function() { // open detail page in new window or tab on double-click
	  var this_section = jQuery(this).attr('name');
	  var categories = get_selected_categories(this_section);
	  var category = categories.pop();
	  switch (category)
	  {
	  case "accessions":
	  case "plots":
	      window.open("../../stock/"+this.value+"/view");
	      break;
	  case "trials":
	      window.open("../../breeders_toolbox/trial/"+this.value);
	      break;
	  case "breeding_programs":
	      window.open("../../breeders/manage_programs");
	      break;
	  case "locations":
	      window.open("../../breeders/locations");
	      break;
	  case "traits":
	      window.open("../../chado/cvterm?action=view&cvterm_id="+this.value);
	      break;
	  default:
	      if (window.console) console.log("no link for this category");
	  }
      });

    jQuery('#open_update_dialog').on('click', function () {
	jQuery('#update_wizard_dialog').modal("show");
	matviews_update_options();
    });

    jQuery('#refresh_lists').on('click', function () {
	create_list_start('Start from a list');
    });


    jQuery('#update_wizard_dialog, #upload_datacollector_phenotypes_dialog, #upload_phenotype_spreadsheet_dialog, #upload_fieldbook_phenotypes_dialog').on("click", '.wiz-update', function () {
	if (window.console) console.log("refreshing materialized views . . .");
	refresh_matviews();
    });

    jQuery('#download_button_excel').on('click', function () {
        var selected = get_selected_trials();
        if (selected.length !== 0) {
	  window.open('/breeders/trials/phenotype/download/'+selected.join(","));
        }
        else { alert("No trials selected for download."); }

    });

    jQuery('#download_button_csv').on('click', function () {
        var selected = get_selected_trials();
        if (selected.length !== 0) {
	  window.open('/breeders/trials/phenotype/download/'+selected.join(",")+'?format=csv');
        }
        else { alert("No trials selected for download."); }

    });

    jQuery('#download_button_genotypes').on('click', function () {
        var accession_ids = get_selected_accessions();
        var protocol_id = get_selected_genotyping_protocols();
        if (accession_ids.length !== 0) {
	  window.open('/breeders/download_gbs_action/?ids='+accession_ids.join(",")+'&protocol_id='+protocol_ids+'&format=ids');
        }
        else { alert("No accessions selected for download."); }

    });
}

function retrieve_and_display_set(categories, data, this_section) {
    if (window.console) console.log("categories = "+categories);
    if (window.console) console.log("data = "+JSON.stringify(data));
    //if (window.console) console.log("querytypes="+get_querytypes(this_section));
    jQuery.ajax( {
	url: '/ajax/breeder/search',
	timeout: 60000,
	method: 'POST',
	data: {'categories': categories, 'data': data, 'querytypes': get_querytypes(this_section)},
	    beforeSend: function(){
		disable_ui();
            },
            complete : function(){
		enable_ui();
            },
	    success: function(response) {
		if (response.error) {
		    var error_html = '<div class="well well-sm" id="response_error"><font color="red">'+response.error+'</font></div>';
		    var selectall_id = "c"+this_section+"_select_all";
		    jQuery('#'+selectall_id).before(error_html);
		}
		else {
                    var list = response.list || [];
		    data_html = format_options_list(list);
		    var data_id = "c"+this_section+"_data";
		    var count_id = "c"+this_section+"_data_count";
		    var listmenu_id = "c"+this_section+"_to_list_menu";
		    var select_id = "select"+this_section;

		    jQuery('#'+data_id).html(data_html);
		    show_list_counts(count_id, list.length);

		    if (isLoggedIn()) {
			addToListMenu(listmenu_id, data_id, {
			    selectText: true,
			    typeSourceDiv: select_id });
		    }
		}
	    },
	error: function(request, status, err) {
		if (status == "timeout") {
                    // report timeout
		    var error_html = '<div class="well well-sm" id="response_error"><font color="red">Timeout error. Request could not be completed within 60 second time limit.</font></div>';
		    var selectall_id = "c"+this_section+"_select_all";
		    jQuery('#'+selectall_id).before(error_html);
		} else {
                    // report unspecified error occured
		    var error_html = '<div class="well well-sm" id="response_error"><font color="red">Unspecified error. If this problem persists, please <a href="../../contact/form">contact developers</a></font></div>';
		    var selectall_id = "c"+this_section+"_select_all";
		    jQuery('#'+selectall_id).before(error_html);
		}
            }

	});
}

function get_selected_data(this_section) {
    var selected_data = [];

    for (i=1; i <= this_section; i++) {
	var element_id = "c"+i+"_data";
	var data = jQuery("#"+element_id).val();
	if (data) selected_data.push(data);
    }
    //if (window.console) console.log("selected data= "+JSON.stringify(selected_data));
    return selected_data;
}

function get_selected_categories(this_section) {

    var selected_categories = [];
    var select1 = jQuery('#select1').val();
    if (select1 === '') { // if starting category is undefined
	var list_id = jQuery('#c1_data_list_select').val();
	if (list_id) { // check to see if paste from list was used, if so get list type
	    var list_id = jQuery('#c1_data_list_select').val();
	    var lo = new CXGN.List();
	    var list_data = lo.getListData(list_id);
	    select1 = list_data.type_name;
	}
    }
    selected_categories.push(select1);
    for (i=2; i <= this_section; i++) {
	var element_id = "select"+i;
	var category = jQuery("#"+element_id).val();
	selected_categories.push(category);
    }
    var next_section = this_section +1;
    var next_select_id = "select"+next_section;
    jQuery("#"+next_select_id).val('please select');
    //if (window.console) console.log("selected categories= "+JSON.stringify(selected_categories));
    return selected_categories;
}

function get_selected_trials () {
    var max_section = 4;
    var selected_trials;
    var categories = get_selected_categories(max_section);
    var data = get_selected_data(max_section);
    for (i=0; i < categories.length; i++) {
	if (categories[i] === 'trials' && data[i]) {
	    selected_trials = data[i];
	} else {
	}
    }
    if (selected_trials.length > 0) {
	return selected_trials;
    } else {
	alert("No trials selected");
    }
}

function get_selected_genotyping_protocols () {
    var max_section = 4;
    var selected_genotyping_protocol;
    var categories = get_selected_categories(max_section);
    var data = get_selected_data(max_section);
    for (i=0; i < categories.length; i++) {
      if (categories[i] === 'genotyping_protocols' && data[i]) {
        selected_genotyping_protocol = data[i];
      }
    }
    if (selected_genotyping_protocol.length == 1) {
      return selected_genotyping_protocol;
    }
    else {
      alert("Please select a single genotyping protocol");
    }
}

function get_selected_accessions () {
    var max_section = 4;
    var selected_accessions;
    var categories = get_selected_categories(max_section);
    var data = get_selected_data(max_section);
    for (i=0; i < categories.length; i++) {
	if (categories[i] === 'accessions' && data[i]) {
	    selected_accessions = data[i];
	} else {
	}
    }
    if (selected_accessions.length > 0) {
	return selected_accessions;
    } else {
	alert("No accessions selected");
    }
}

function update_select_categories(this_section) {
    var selected_categories = get_selected_categories(this_section);

    var categories = { '': 'please select', accessions : 'accessions', breeding_programs: 'breeding_programs', genotyping_protocols : 'genotyping_protocols', locations : 'locations', plots : 'plots', traits : 'traits', trials :'trials', years : 'years'};
    var all_categories = copy_hash(categories);

    for (i=0; i < this_section; i++) {
	delete all_categories[selected_categories[i]];
    }
    var remaining_categories = format_options(all_categories);
    var next_section = ++this_section;
    var next_select_id = "select"+next_section;

    jQuery('#'+next_select_id).html(remaining_categories);
}

function update_download_options(this_section) {
    var categories = get_selected_categories(this_section);
    var data = get_selected_data(this_section);
    var selected_trials = 0;
    var selected_accessions= 0;
    var selected_genotyping_protocols = 0;
    for (i=0; i < categories.length; i++) {
	//if (categories[i]) {console.log("category ="+categories[i]);}
	//if (data !== undefined) {console.log("data ="+data[i]);}
      if (categories[i] === 'trials' && data[i]) {
        selected_trials = 1;
	      jQuery('#download_button_excel').prop( 'title', 'Click to Download Trial Phenotypes');
        jQuery('#download_button_csv').prop('title', 'Click to Download Trial Phenotypes');
        jQuery('#download_button_excel').removeAttr('disabled');
        jQuery('#download_button_csv').removeAttr('disabled');
        var trial_html = '<font color="green">'+data[i].length+' trials selected</font></div>';
        jQuery('#selected_trials').html(trial_html);
      }
      if (categories[i] === 'accessions' && data[i]) {
        selected_accessions = 1;
        var accession_html = '<font color="green">'+data[i].length+' accessions selected</font></div>';
        jQuery('#selected_accessions').html(accession_html);
      }
      if (categories[i] === 'genotyping_protocols' && data[i]) {
        selected_genotyping_protocols = 1;
        var genotyping_protocols_html = '<font color="green">'+data[i].length+' genotyping protocols selected</font></div>';
        jQuery('#selected_genotyping_protocols').html(genotyping_protocols_html);
      }
    }
    if (selected_accessions == 1 && selected_genotyping_protocols == 1) {
      jQuery('#download_button_genotypes').prop( 'title', 'Click to Download Accession Genotypes');
	    jQuery('#download_button_genotypes').removeAttr('disabled');
    }
    //console.log("trials-selected="+trials_selected);
    //console.log("accessions-selected="+accessions_selected);
    if (selected_trials !== 1) {
      jQuery('#download_button_excel').prop('title','First select a trial or trials to download');
      jQuery('#download_button_csv').prop('title', 'First select a trial or trials to download');
      jQuery('#download_button_excel').attr('disabled', 'disabled');
      jQuery('#download_button_csv').attr('disabled', 'disabled');
      jQuery('#selected_trials').html('No trials selected');
    }
    if (selected_accessions !== 1) {
      jQuery('#download_button_genotypes').prop('title','First select a genotyping protocol and accessions to download');
      jQuery('#download_button_genotypes').attr('disabled', 'disabled');
      jQuery('#selected_accessions').html('No accessions selected');
    }
    if (selected_genotyping_protocols !== 1) {
      jQuery('#download_button_genotypes').prop('title','First select a genotyping protocol and accessions to download');
      jQuery('#download_button_genotypes').attr('disabled', 'disabled');
      jQuery('#selected_genotyping_protocols').html('No genotyping protocols selected');
    }
}

function reset_downstream_sections(this_section) {  // clear downstream selects, data_panels, data_counts
    jQuery('#response_error').remove();
    for (i = 4; i > this_section; i--) {
	var select_id = "select"+i;
	var data_id = "c"+i+"_data";
	var count_id = "c"+i+"_data_count";
	var querytype_id = "c"+i+"_querytype";
	jQuery('#'+select_id).html('');
	jQuery('#'+data_id).html('');
	jQuery('#'+count_id).html('');
	jQuery('#'+querytype_id).bootstrapToggle('off');
    }
}

function create_list_start(message) {
    var lo = new CXGN.List();
    var listhtml = lo.listSelect('c1_data', '', message);
    jQuery('#paste_list').html(listhtml);
    jQuery('#paste_list').change(
    function() { // if 'select a list', reinitialize, otherwise paste list
      jQuery('#list_message').html('');
      var value = jQuery('#c1_data_list_select').val();
      if (window.console) console.log("c1_data_list_select_val ="+value);
    if (value === '') {
        jQuery('#c1_data').html('');
      }
    else {  // paste list by retrieving ids and combing them with list values in proper format
      disable_ui();
      var lo = new CXGN.List();
      var list_id = jQuery('#c1_data_list_select').val();
      var data = lo.getListData(list_id);
      if (window.console) console.log("list_data="+JSON.stringify(data));
      if (data === undefined) {
        report_list_start_error("Unable to retrieve data from this list.");
        return;
      }
      if (data.type_name === '') {
        report_list_start_error("Unable to start from a list of type null.");
        return;
      }
      if (data.type_name !== 'years') { // retrieve ids if they exist
        var ids = lo.transform2Ids(list_id);
        if (window.console) console.log("list_ids="+JSON.stringify(ids));
        if (ids === undefined) {
          report_list_start_error("Unable to retrieve ids from this list.");
          return;
        }
      }

      var elements = data.elements;
      var options = [];
      for (var n=0; n<elements.length; n++) { // format ids and names of list elements to display
        if (data.type_name === 'years') {
          options.push([elements[n][1], elements[n][1]]);
        }
        else {
          options.push([ids[n], elements[n][1]]);
        }
      }

      c1_html = format_options_list(options);
      jQuery('#c1_data_text').html(retrieve_sublist(options, 1).join("\n"));
      jQuery('#c1_data').html(c1_html);

      // clear and reset all other wizard parts
      var this_section = 1;
      initialize_first_select();
      show_list_counts('c1_data_count', options.length);
      reset_downstream_sections(this_section);
	    update_select_categories(this_section);
      update_download_options(this_section);

      if (isLoggedIn()) {
        addToListMenu('c1_to_list_menu', 'c1_data', {
          selectText: true,
          listType: data.type_name });
      }
      enable_ui();
    }
  });
}

function report_list_start_error(error_message) {
  enable_ui();
  var error_html = '<div class="well well-sm"><font color="red">'+error_message+'</font></div>';
  jQuery('#list_message').html(error_html);
}

function format_options(items) {
    var html = '';
    for (var key in items) {
	html = html + '<option value="'+key+'" title="'+items[key]+'">'+items[key]+'</a>\n';
    }
    return html;
}

function retrieve_sublist(list, sublist_index) {
    var new_list = new Array();
    for(var i=0; i<list.length; i++) {
	new_list.push(list[i][sublist_index]);
    }
    return new_list;
}

function format_options_list(items) {
    var html = '';
    if (items) {
	for(var i=0; i<items.length; i++) {
	    html = html + '<option value="'+items[i][0]+'" title="'+items[i][1]+'">'+items[i][1]+'</a>\n';
	}
	return html;
    }
    return "no data";
}

function copy_hash(hash) {
    var new_hash = new Array();

    for (var key in hash) {
	new_hash[key] = hash[key];
    }
     return new_hash;
}

function disable_ui() {
    jQuery('#working_modal').modal("show");
}

function enable_ui() {
     jQuery('#working_modal').modal("hide");
}

function show_list_counts(count_div, total_count, selected) {
    var html = 'Items: '+total_count+'<br />';
    if (selected) {
	html += 'Selected: '+selected;
    }
    jQuery('#'+count_div).html(html);
}

function selectAllOptions(obj) {
    if (!obj || obj.options.length ==0) { return; }
    for (var i=0; i<obj.options.length; i++) {
      obj.options[i].selected = true;
    }
}

function check_missing_criteria(categories, data, this_section) {
    var test = data.length + 1;
    if (categories.length > test) {
	var error_html = '<div class="well well-sm" id="response_error"><font color="red">Error: Select at least one option from each preceding panel</font></div>';
	var selectall_id = "c"+this_section+"_select_all";
	jQuery('#'+selectall_id).before(error_html);
	return 1;
    } else {
	return 0;
    }
}

function get_querytypes(this_section) {
    var querytypes = [];

    for (i=2; i <= this_section; i++) {
	var element_id = "c"+i+"_querytype";
	if (jQuery('#'+element_id).is(":checked")) {
	    var type = 1;
	} else {
	    var type = 0;
	}
	if (window.console) console.log("querytype="+type);
	querytypes.push(type);
    }
    if (querytypes.length > 0) {
    return querytypes;
    }
}

function initialize_first_select() {
  var starting_categories = { '': 'Select a starting category', breeding_programs: 'breeding_programs', genotyping_protocols : 'genotyping_protocols', locations : 'locations', traits : 'traits', trials :'trials', years : 'years'};
  var start = format_options(starting_categories);
  jQuery('#select1').html(start);
}

function add_data_refresh() {
    var roles = getUserRoles();
    console.log("userroles="+roles);
    if (jQuery.inArray(roles, ['submitter', 'curator', 'sequencer']) >= 0) {
	jQuery('#wizard_refresh').append('<p align="center" style="margin: 0px 0"><i>Don\'t see your data?</i></p><input class="btn btn-link center-block" id="open_update_dialog" type="button" value="Update wizard">');
    }
}

function refresh_matviews() {
    jQuery.ajax( {
	url: '/ajax/breeder/refresh',
	timeout: 60000,
	method: 'POST',
	beforeSend: function() {
	    jQuery('#update_wizard').button('loading');
	},
	success: function(response) {
		if (response.error) {
		    var error_html = '<div class="well well-sm" id="update_wizard_error"><font color="red">'+response.error+'</font></div>';
		    jQuery('#update_wizard_error').replaceWith(error_html);
		} else {
		    var success_html = '<div class="well well-sm" id="update_wizard_error"><font color="green">Success! Update initiated.</font></div>';
		    jQuery('#update_wizard_error').replaceWith(success_html);
		    matviews_update_options();
		}
	    },
	error: function(request, status, err) {
		if (status == "timeout") {
                    // report timeout
		    var error_html = '<div class="well well-sm" id="update_wizard_error"><font color="red">Timeout error. Request could not be completed within 60 second time limit.</font></div>';
		    jQuery('#update_wizard_error').replaceWith(error_html);
		} else {
                    // report unspecified error occured
		    var error_html = '<div class="well well-sm" id="update_wizard_error"><font color="red">Unspecified error. If this problem persists, please <a href="../../contact/form">contact developers</a></font></div>';
		    jQuery('#update_wizard_error').replaceWith(error_html);
		}
            }
    });
}

function matviews_update_options() {
    jQuery.ajax( {
	url: '/ajax/breeder/check_status',
	timeout: 60000,
	method: 'POST',
	success: function(response) {
		if (response.refreshing) {
		    // if already refreshing, display status in modal and create disabled button
	            var update_status = response.refreshing;
		    jQuery('#wizard_status').replaceWith(update_status);
		    var button_html = '<button type="button" class="btn btn-primary wiz-update" name="update_wizard" data-loading-text="Working..." id="update_wizard" title="A search wizard update is already in progress..." disabled>Update search wizard</button>';
		    jQuery('#update_wizard').replaceWith(button_html);
		} else if (response.timestamp) {
		    // if exists display timestamp in modal and create button
		    var update_status = response.timestamp;
		    jQuery('#wizard_status').replaceWith(update_status);
		    var button_html = '<button type="button" class="btn btn-primary wiz-update" name="update_wizard" data-loading-text="Working..." id="update_wizard" title="Refresh the search wizard to include newly uploaded data">Update search wizard</button>';
		    jQuery('#update_wizard').replaceWith(button_html);
		}
	    },
	error: function(request, status, err) {
		if (status == "timeout") {
                    // report timeout
		    var error_html = '<div class="well well-sm" id="wizard_status"><font color="red">Timeout error. Request could not be completed within 60 second time limit.</font></div>';
		    jQuery('#wizard_status').replaceWith(error_html);
		} else {
                    // report unspecified error occured
		    var error_html = '<div class="well well-sm" id="wizard_status"><font color="red">Unspecified error. If this problem persists, please <a href="../../contact/form">contact developers</a></font></div>';
		    jQuery('#wizard_status').replaceWith(error_html);
		}
            }
    });
}
