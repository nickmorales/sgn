/** 
* breeding values vs phenotypic deviation 
* plotting using d3
* Isaak Y Tecle <iyt2@cornell.edu>
*
*/

JSAN.use('statistics.jsStats');


function getDataDetails () {

    var populationId   = jQuery("#population_id").val();
    var traitId        = jQuery("#trait_id").val();
   
    if(populationId == 'undefined' ) {       
        populationId = jQuery("#model_id").val();
    }

    if(populationId == 'undefined') {
        populationId = jQuery("#combo_pops_id").val();
    }

    return {'population_id' : populationId, 
            'trait_id' : traitId
            };
        
}


function checkDataExists () {
    var dataDetails  = getDataDetails();
    var traitId      = dataDetails.trait_id;
    var populationId = dataDetails.population_id;

    var dataExists;
    jQuery.ajax({
        type: 'POST',
        dataType: 'json',
        data: {'population_id': populationId, 'trait_id': traitId },
        url: '/heritability/check/data/',
        success: function(response) {
            if(response.exists == 'yes') {               
                dataExists = true;
            } else {                
                dataExists = false;
            }
        },
        error: function(response) {                    
            // alert('there is error in checking the dataset for heritability analysis.');
            dataExists = false;
        }
    });
   
    return dataExists;
}


function getRegressionData () {
    var dataExists = checkDataExists();
    
    if (dataExists == true) {
     
        var dataDetails  = getDataDetails();
        var traitId      = dataDetails.trait_id;
        var populationId = dataDetails.population_id;
        
        var breedingValues  = [];
        var phenotypeValues = [];

        jQuery.ajax({
            type: 'POST',
            dataType: 'json',
            data: {'population_id': populationId, 'trait_id': traitId },
            url: '/heritability/regression/data/',
            success: function(response) {
                if(response.status == 'success') {
                    breedingValues  = response.gebv_data;
                    phenotypeValues = response.pheno_data;

                    return {
                        'breeding_values'  : breedingValues,
                        'phenotype_values' : phenotypeValues
                    }
                } else {
                    
                    return;
                }
            },
            error: function(response) {                    
                // alert('there is porblem getting regression data.');
                return;
            }
        });

    }
}


function plotRegressionData(){
   var regressionData =  getRegressionData();
    
}


jQuery(document).ready( function () { 
    plotRegressionData();
 });






