$(document).ready(function(){
	
	// fourth example
	$("#gray").treeview({
		control: "#treecontrol",
        collapsed: true,
        animated: "fast",
		persist: "cookie",
		cookieId: "treeview-grey",
        unique: true,
	});

});